# DNF — service parameter resolution
#
# Resolves the effective parameters of a service (domain, FQDN, href, IP,
# display metadata) by merging the network entry, the module defaults and
# values derived from the host topology. Also exposes the small activation
# fragment every service module repeats. Pure and side-effect free.

{
  lib,
  strings,
  topology,
}:
let
  inherit (lib) hasAttrByPath;
in
rec {

  # Effective parameters of `service` hosted on `serviceHost`. Each field comes
  # from the network entry, else the module `defaults` (empty string = unset),
  # else a value derived from the name and the host topology.
  buildServiceParams =
    serviceHost: network: service: defaults:
    let
      inherit (service) name;
      ucName = strings.ucFirst name;

      # String field: an empty module default falls through to `fallback`.
      pick =
        key: fallback:
        service.${key} or (if (defaults.${key} or "") != "" then defaults.${key} else fallback);

      domain = pick "domain" name;
      global = service.global or defaults.global or false;
      fqdn =
        if global then "${domain}.${serviceHost.networkDomain}" else "${domain}.${serviceHost.zoneDomain}";

      # On the HCS services answer on loopback; elsewhere the tailnet IP wins.
      isOnHcs =
        hasAttrByPath [ "coordination" "hostname" ] network
        && serviceHost.hostname == network.coordination.hostname;
      topologyIp =
        if isOnHcs then
          "127.0.0.1"
        else if topology.isVpnClient serviceHost then
          serviceHost.vpnIp
        else
          serviceHost.ip;
    in
    {
      inherit domain global fqdn;
      title = pick "title" ucName;
      description = pick "description" "${ucName} local service";
      icon = "sh-" + pick "icon" name;
      noRobots = service.noRobots or defaults.noRobots or true;
      zone = service.zone or serviceHost.zone;
      host = service.host or serviceHost.hostname;
      href = (if network.coordination.enable then "https://" else "http://") + fqdn;
      ip = pick "ip" topologyIp;
    };

  # `buildServiceParams` on the network entry of `serviceName` on this host;
  # without one, every field falls back on `defaults` and the topology.
  extractServiceParams =
    serviceHost: network: serviceName: defaults:
    let
      overloadParams = lib.findFirst (
        s: s.name == serviceName && s.host == serviceHost.hostname && s.zone == serviceHost.zone
      ) { } network.services;
    in
    buildServiceParams serviceHost network overloadParams defaults;

  # Public URL of service `name` wherever it is deployed, `null` when it is
  # not. `preferZone` picks the caller's own instance on a multi-zone
  # deployment, else the first declared one.
  serviceHref =
    {
      name,
      network,
      hosts,
      preferZone ? null,
      defaults ? { },
    }:
    let
      matches = lib.filter (s: s.name == name) network.services;
      preferred = lib.filter (s: s.zone == preferZone) matches;
      candidates = if preferred != [ ] then preferred else matches;
    in
    if candidates == [ ] then
      null
    else
      let
        svc = lib.head candidates;
      in
      (buildServiceParams (topology.findHost svc.host svc.zone hosts) network svc defaults).href;

  # `darkone.system.services` fragment every service module sets under
  # `lib.mkIf cfg.enable`.
  enableBlock = name: {
    enable = true;
    service.${name}.enable = true;
  };
}
