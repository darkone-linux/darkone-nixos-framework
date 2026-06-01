# DNF — service parameter resolution
#
# Resolves the effective parameters of a service (domain, FQDN, href, IP,
# display metadata) by merging the network entry, the module defaults and
# values derived from the host topology. Also exposes the small activation
# fragment every service module repeats. Pure and side-effect free.

{ lib, strings }:
let
  inherit (lib) hasAttr hasAttrByPath;
in
rec {

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
      overloadParams = lib.findFirst (
        s: s.name == serviceName && s.host == serviceHost.hostname && s.zone == serviceHost.zone
      ) { } network.services;
    in
    buildServiceParams serviceHost network overloadParams defaults;

  # Activation fragment systematically repeated inside `lib.mkIf cfg.enable`
  # blocks of every DNF service module. Returns the attrset that should be
  # assigned to `darkone.system.services`.
  enableBlock = name: {
    enable = true;
    service.${name}.enable = true;
  };
}
