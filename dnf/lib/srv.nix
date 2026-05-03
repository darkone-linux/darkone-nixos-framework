# DNF — services helpers
#
# Pure helpers that resolve service-related values (parameters, host
# membership, firewall paths) from the flat data structures coming out of
# `var/generated/` (hosts, network, services). All functions are total and
# free of side effects so they can be reused by any DNF module.

{
  lib,
  strings,
  constants,
}:
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

  # Resolve effective service parameters by merging, in order:
  # 1. fields explicitly set on the network service entry,
  # 2. defaults declared by the service module,
  # 3. derived values (FQDN, href, IP) computed from the host topology.
  #
  # Empty strings in defaults are treated as missing so the derived values
  # take over (eg. `domain` falls back to the service name).
  #
  # Used as a building block by `extractServiceParams`.
  buildServiceParams =
    serviceHost: network: service: defaults:
    let
      inherit (service) name;
      ucName = strings.ucFirst name;
      domain =
        if hasAttr "domain" service then
          service.domain
        else if (hasAttr "domain" defaults) && defaults.domain != "" then
          defaults.domain
        else
          name;
      title =
        if hasAttr "title" service then
          service.title
        else if (hasAttr "title" defaults) && defaults.title != "" then
          defaults.title
        else
          ucName;
      description =
        if hasAttr "description" service then
          service.description
        else if (hasAttr "description" defaults) && defaults.description != "" then
          defaults.description
        else
          "${ucName} local service";
      icon =
        "sh-"
        + (
          if hasAttr "icon" service then
            service.icon
          else if (hasAttr "icon" defaults) && defaults.icon != "" then
            defaults.icon
          else
            name
        );
      global =
        if hasAttr "global" service then
          service.global
        else if hasAttr "global" defaults then
          defaults.global
        else
          false;
      noRobots =
        if hasAttr "noRobots" service then
          service.noRobots
        else if hasAttr "noRobots" defaults then
          defaults.noRobots
        else
          true;
      zone = if hasAttr "zone" service then service.zone else serviceHost.zone;
      host = if hasAttr "host" service then service.host else serviceHost.hostname;
      fqdn =
        if global then "${domain}.${serviceHost.networkDomain}" else "${domain}.${serviceHost.zoneDomain}";
      href = (if network.coordination.enable then "https://" else "http://") + fqdn;

      # IP resolution cascade:
      # 1. value explicitly set on the service or its defaults,
      # 2. on the HCS itself, services answer on loopback (127.0.0.1),
      # 3. external host registered in our tailnet -> reach via vpnIp,
      # 4. plain host in a local zone -> reach via host.ip.
      ip =
        if hasAttr "ip" service then
          service.ip
        else if (hasAttr "ip" defaults) && defaults.ip != "" then
          defaults.ip
        else if
          (hasAttrByPath [ "coordination" "hostname" ] network)
          && (serviceHost.hostname == network.coordination.hostname)
        then
          "127.0.0.1"
        else if (hasAttr "vpnIp" serviceHost) && serviceHost.vpnIp != "" then
          serviceHost.vpnIp
        else
          serviceHost.ip;
    in
    {
      inherit domain;
      inherit title;
      inherit description;
      inherit icon;
      inherit global;
      inherit noRobots;
      inherit zone;
      inherit host;
      inherit fqdn;
      inherit href;
      inherit ip;
    };

  # Look up a service entry matching the (host, zone) pair and call
  # `buildServiceParams` on it. When no entry is found, an empty attrset is
  # passed so all values fall back on `defaults` and topology.
  extractServiceParams =
    serviceHost: network: serviceName: defaults:
    let
      overloadParams = findFirst (
        s: s.name == serviceName && s.host == serviceHost.hostname && s.zone == serviceHost.zone
      ) { } network.services;
    in
    buildServiceParams serviceHost network overloadParams defaults;

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

  # Path inside `networking.firewall` selecting the internal interface to
  # which a service should be exposed. Returns `[]` for hosts that have no
  # internal interface (eg. external clients without VPN).
  #
  # Usage:
  #   networking.firewall = lib.setAttrByPath
  #     (dnfLib.getInternalInterfaceFwPath host zone)
  #     { allowedTCPPorts = [ port ]; };
  getInternalInterfaceFwPath =
    host: zone:
    if (isGateway host zone) then
      [
        "interfaces"
        constants.lanInterface
      ]
    else
      (
        if (isVpnClient host) then
          [
            "interfaces"
            constants.vpnInterface
          ]
        else
          [ ]
      );
}
