# Services helpers

{ lib, strings }:
with lib;
rec {
  # Extract params to use in the service.
  extractServiceParams =
    serviceHost: network: serviceName: defaults:
    let
      overloadParams = lib.findFirst (
        s: s.name == serviceName && s.host == serviceHost.hostname && s.zone == serviceHost.zone
      ) { } network.services;
    in
    buildServiceParams serviceHost network overloadParams defaults;

  # Params calculated and used in services.nix
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
      zone = if hasAttr "zone" service then service.zone else serviceHost.zone;
      host = if hasAttr "host" service then service.host else serviceHost.hostname;
      fqdn =
        if global then "${domain}.${serviceHost.networkDomain}" else "${domain}.${serviceHost.zoneDomain}";
      href = (if network.coordination.enable then "https://" else "http://") + fqdn;
      ip =
        if hasAttr "ip" service then
          service.ip
        else if (hasAttr "ip" defaults) && defaults.ip != "" then
          defaults.ip
        else
          serviceHost.ip;
    in
    {
      inherit domain;
      inherit title;
      inherit description;
      inherit icon;
      inherit global;
      inherit zone;
      inherit host;
      inherit fqdn;
      inherit href;
      inherit ip;
    };
}
