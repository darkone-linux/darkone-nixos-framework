# DNF — network topology helpers
#
# Pure lookups and predicates over the flat data structures coming out of
# `var/generated/` (hosts, zones, services). They answer "where does this
# host/service sit in the network?" — gateway, VPN client, HCS, local zone —
# and resolve preferred IPs. All functions are total and side-effect free.

{ lib, constants }:
let
  inherit (lib) hasAttr hasAttrByPath findFirst;
in
rec {

  # Look up a host by hostname and zone in a list of hosts.
  # Returns `{}` when not found, matching the convention used by the rest
  # of the helpers (callers may then probe with `hasAttr` before access).
  findHost =
    hostname: zoneName: hosts:
    findFirst (h: h.hostname == hostname && h.zone == zoneName) { } hosts;

  # Look up a service by name and zone in a list of services.
  # Returns `null` when not found so callers can branch explicitly.
  findService =
    serviceName: zoneName: services:
    findFirst (s: s.name == serviceName && s.zone == zoneName) null services;

  # True when `host` has a non-empty `vpnIp` field, ie. when it is
  # registered as a headscale (tailscale) client. The non-empty check
  # avoids classifying a host as VPN client based solely on the attribute
  # being present (the generated data may emit empty strings).
  isVpnClient = host: hasAttr "vpnIp" host && host.vpnIp != "";

  # True when `host` is the gateway of a local zone. A VPN client is never
  # a gateway by construction.
  isGateway =
    host: zone:
    !(isVpnClient host)
    && hasAttrByPath [ "gateway" "hostname" ] zone
    && host.hostname == zone.gateway.hostname;

  # True when `zone` is a local zone (not the global, Internet-facing one).
  inLocalZone = zone: zone.name != constants.globalZone;

  # True when `host` is the headscale coordination server (HCS) of the
  # network. The HCS lives in the global zone and matches the coordination
  # hostname declared at the network level.
  isHcs =
    host: zone: network:
    (!(inLocalZone zone))
    && network.coordination.enable
    && network.coordination.hostname == host.hostname;

  # Tailnet IP when registered, else `ip`, else loopback: the address another
  # zone reaches the host on.
  preferredIp =
    host:
    if isVpnClient host then
      host.vpnIp
    else if (host.ip or "") != "" then
      host.ip
    else
      "127.0.0.1";

  # Resolve which host serves `name` in this zone, seen from `host`.
  #
  # Server side only: a service whose clients are opt-in per host (cf. `stk`)
  # has no fleet-wide client list to derive. `count` is exposed so callers can
  # assert the single-server invariant.
  resolveZoneService =
    {
      name,
      host,
      hosts,
      zone,
      services,
    }:
    let
      matches = builtins.filter (s: s.name == name && s.zone == zone.name) services;
      count = builtins.length matches;
      server = if matches == [ ] then null else (builtins.head matches).host;
      serverHost = if server == null then { } else findFirst (h: h.hostname == server) { } hosts;
    in
    {
      inherit count server serverHost;
      hasServer = count == 1;
      isServer = server != null && host.hostname == server;
    };

  # NFS topology seen from `host`: the zone server, and whether this host is it
  # or one of its clients. A client carries the `nfs-client` feature pointing
  # at the server's own zone: cross-zone clients are not wired yet.
  resolveNfs =
    {
      host,
      hosts,
      zone,
      services,
    }:
    let
      nfs = resolveZoneService {
        name = "nfs";
        inherit
          host
          hosts
          zone
          services
          ;
      };

      # Client predicate, applied to any host of the fleet.
      isClientHost =
        h:
        nfs.hasServer
        && h.hostname != nfs.server
        && hasAttr "nfs-client" (h.features or { })
        && h.features.nfs-client == (nfs.serverHost.zone or null);

      # `exports(5)` client list: a zone prefix there shares every home with
      # whatever obtains a LAN address, Wi-Fi guest included. Sorted for a
      # stable /etc/exports across regenerations.
      clientIps = lib.sort (a: b: a < b) (
        lib.unique (map (h: h.ip) (lib.filter (h: isClientHost h && (h.ip or "") != "") hosts))
      );
    in
    {
      inherit (nfs)
        count
        server
        hasServer
        isServer
        ;
      inherit clientIps;
      isClient = isClientHost host;
    };
}
