# DNF Service registration and configuration.
#
# :::caution[Special internal module]
# This module is used to register and configure DNF modules:
# - Reverse proxy (caddy)
# - Homepage registration
# - DNS entry
# - folders and files to backup
# :::

{
  lib,
  config,
  host,
  network,
  ...
}:
with lib;
let
  cfg = config.darkone.system.services;

  # Full list of registered services in current host
  allServices = config.darkone.system.services.service;
  enabledServices = filterAttrs (_: v: v.enable) config.darkone.system.services.service;

  # If not a gateway, open HTTP
  isGateway = host.hostname == network.gateway.hostname;

  # Service parameter makers
  mkDomainName =
    name: defaultDomain:
    if attrsets.hasAttrByPath [ "services" "${name}" "domain" ] host then
      host.services."${name}".domain
    else
      defaultDomain;
  mkDisplayName =
    name: defaultDisplayName:
    if attrsets.hasAttrByPath [ "services" "${name}" "title" ] host then
      host.services."${name}".title
    else
      defaultDisplayName;
  mkDescription =
    name: defaultDescription:
    if attrsets.hasAttrByPath [ "services" "${name}" "description" ] host then
      host.services."${name}".description
    else
      defaultDescription;
  mkIcon =
    name: defaultIcon:
    "sh-"
    + (
      if attrsets.hasAttrByPath [ "services" "${name}" "icon" ] host then
        host.services."${name}".icon
      else
        defaultIcon
    );

  # Shared services parameters
  mkSrvValue =
    srv: key: if builtins.hasAttr "${key}" srv then srv.${key} else allServices.${srv.service}.${key};
in
{
  options = {
    darkone.system.services.enable = mkEnableOption "Enable DNF services manager to register a new service";

    # Service registration options
    # TODO: implementation for "persist" files and dirs
    darkone.system.services.service = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              enable = mkEnableOption "Enable service proxy";

              # Domain (DNS)
              domainName = mkOption {
                type = types.str;
                default = name;
                description = "Domain name for the service";
              };

              # Homepage settings
              displayOnHomepage = mkOption {
                type = types.bool;
                default = true;
                description = "Display a link on homepage";
              };
              displayName = mkOption {
                type = types.str;
                default = name;
                description = "Display name in homepage";
              };
              description = mkOption {
                type = types.str;
                default = name;
                description = "Service description for homepage";
              };
              icon = mkOption {
                type = types.str;
                default = name;
                description = "Icon name for homepage (https://dashboardicons.com/)";
              };

              # Folders and files to persist
              persist = {
                dirs = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  example = [ "/var/lib/immich" ];
                  description = "Service persistant dirs";
                };
                files = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Service persistant files";
                };
                dbDirs = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  example = [ "/var/lib/postgresql" ];
                  description = "Service persistant dirs with database(s)";
                };
                dbFiles = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  description = "Service database file(s)";
                };
                varDirs = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  example = [
                    "/var/cache"
                    "/var/log"
                  ];
                  description = "Variable secondary files (log, cache, etc.)";
                };
                mediaDirs = mkOption {
                  type = types.listOf types.str;
                  default = [ ];
                  example = [
                    "/var/lib/immich/encoded-video"
                    "/var/lib/immich/library"
                    "/var/lib/immich/upload"
                  ];
                  description = "Service media dirs (pictures, videos, big files)";
                };
              };

              # Reverse proxy settings
              proxy = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Whether to create virtualHost configuration (false for services that manage their own)";
                };
                defaultService = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Is the default service";
                };
                servicePort = mkOption {
                  type = types.nullOr types.port;
                  default = null;
                  description = "Service internal port";
                };
                extraConfig = mkOption {
                  type = types.lines;
                  default = "";
                  description = "Extra caddy virtualHost configuration";
                };
              };
            };
          }
        )
      );
      default = { };
      description = "Global services configuration";
    };
  };

  # TODO: TLS
  config = mkIf cfg.enable {

    # Reverse proxy
    services.caddy = {
      enable = mkForce true;

      # TMP
      globalConfig = ''
        auto_https off
      '';

      # Configure virtual hosts (TODO: https)
      virtualHosts = mkMerge (
        mapAttrsToList (
          name: srv:
          let
            shortDomain = mkDomainName name srv.domainName;
            fqdn = "${shortDomain}.${network.domain}";
            isValid = srv.proxy.enable && (srv.proxy.servicePort != null);
            isDefault = isValid && srv.proxy.defaultService;
          in
          #isDefaultNotHostname = isDefault && (fqdn != "${host.hostname}.${network.domain}");
          mkIf isValid {

            # Short name -> FQDN
            "http://${shortDomain}" = {
              extraConfig = ''
                # TODO: redir http://${fqdn}{uri} permanent
                redir http://${fqdn}{uri}
              '';
            };

            # Reverse proxy to the target service
            "http://${fqdn}" = {
              extraConfig = ''
                reverse_proxy http://localhost:${toString srv.proxy.servicePort} {
                    header_up X-Forwarded-Proto {scheme}
                    header_up X-Forwarded-Host {host}
                    header_up X-Forwarded-For {remote}
                    header_up Host {upstream_hostport}
                }
                ${srv.proxy.extraConfig}
              '';
            };

            # Redirection to right domain for default service
            # "http://${host.hostname}.${network.domain}" = mkIf isDefaultNotHostname {
            #   extraConfig = ''
            #     redir /${host.hostname}.${network.domain} http://${fqdn}
            #   '';
            # };

            # Redirection to default domain if needed
            ":80, :443" = mkIf isDefault {
              extraConfig = ''
                # TODO: redir http://${fqdn} permanent
                redir http://${fqdn}
              '';
            };
          }
        ) enabledServices
      );
    };

    # Add domains to /etc/hosts
    networking.hosts = mkMerge (
      mapAttrsToList (
        name: srv:
        mkIf config.services.dnsmasq.enable { "${host.ip}" = [ (mkDomainName name srv.domainName) ]; }
      ) enabledServices
    );

    # Add services to homepage
    darkone.service.homepage.appServices =
      mkIf (!isGateway) (
        mapAttrsToList (name: srv: {
          ${(mkDisplayName name srv.displayName)} = mkIf srv.displayOnHomepage {
            description = mkDescription name srv.description;
            href = "http://${(mkDomainName name srv.domainName)}.${network.domain}";
            icon = mkIcon name srv.icon;
          };
        }) enabledServices
      )
      // mkIf isGateway (
        map
          (srv: {
            ${(mkSrvValue srv "displayName")} = {
              description = (mkSrvValue srv "description") + " (" + srv.host + ")";
              href = "http://${(mkSrvValue srv "domainName")}.${network.domain}";
              icon = mkSrvValue srv "icon";
            };
          })
          (
            builtins.filter (
              srv: (hasAttr srv.service allServices) && allServices.${srv.service}.displayOnHomepage
            ) network.sharedServices
          )
      );

    # Open right ports
    # TODO: HTTPS
    networking.firewall = {

      # Open HTTP on all interfaces if not the gateway
      allowedTCPPorts = lib.mkIf (!isGateway) [ 80 ];

      # Open HTTP port only for lan interface(s)
      # TODO: simplify + adapt to headscale
      interfaces = mkIf (isGateway && config.services.dnsmasq.enable) (
        lib.listToAttrs (
          map (iface: {
            name = iface;
            value = {
              allowedTCPPorts = [ 80 ];
            };
          }) config.services.dnsmasq.settings.interface
        )
      );
    };
  };
}
