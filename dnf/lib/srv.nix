# Services helpers

{ lib, strings }:
with lib;
{
  # params = dnfLib.srv.extractServiceParams host network "forgejo" {
  #   domain = "forgejo"; # optional, default is name
  #   title = "Forgejo";
  #   description = "Local GIT Forge";
  #   icon = "forgejo";
  #   global = false;
  # };
  extractServiceParams =
    host: network: name: defaults:
    let
      ucName = strings.ucFirst name;
      domain =
        if attrsets.hasAttrByPath [ "services" "${name}" "domain" ] host then
          host.services."${name}".domain
        else if hasAttr "domain" defaults then
          defaults.domain
        else
          name;
      title =
        if attrsets.hasAttrByPath [ "services" "${name}" "title" ] host then
          host.services."${name}".title
        else if hasAttr "title" defaults then
          defaults.title
        else
          ucName;
      description =
        if attrsets.hasAttrByPath [ "services" "${name}" "description" ] host then
          host.services."${name}".description
        else if hasAttr "description" defaults then
          defaults.description
        else
          "${ucName} local service";
      icon =
        "sh-"
        + (
          if attrsets.hasAttrByPath [ "services" "${name}" "icon" ] host then
            host.services."${name}".icon
          else if hasAttr "icon" defaults then
            defaults.icon
          else
            name
        );
      global =
        if attrsets.hasAttrByPath [ "services" "${name}" "global" ] host then
          host.services."${name}".global
        else if hasAttr "global" defaults then
          defaults.global
        else
          false;
      fqdn = if global then "${domain}.${host.networkDomain}" else "${domain}.${host.zoneDomain}";
      href = (if network.coordination.enable then "https://" else "http://") + fqdn;
      ip = if global then host.ip else "127.0.0.1";
    in
    {
      inherit domain;
      inherit title;
      inherit description;
      inherit icon;
      inherit global;
      inherit fqdn;
      inherit href;
      inherit ip;
    };
}
