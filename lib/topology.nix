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

  # Resolve the preferred IP of a host: tailnet IP when registered, plain
  # `ip` otherwise, falling back to loopback when neither is known. Mirrors
  # the cascade used internally by `buildServiceParams` so consumer modules
  # do not have to re-implement it.
  preferredIp =
    host:
    if (hasAttr "vpnIp" host) && host.vpnIp != "" then
      host.vpnIp
    else if (hasAttr "ip" host) && host.ip != "" then
      host.ip
    else
      "127.0.0.1";
}
