# DNF Service registration and configuration.
#
# :::caution[Special internal module]
# This module is used to register and configure DNF modules:
# - Reverse proxy (nginx)
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
              nginx = {
                manageVirtualHost = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Whether to create nginx virtualHost configuration (false for services that manage their own)";
                };
                defaultVirtualHost = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Default nginx virtualhost";
                };
                proxyPort = mkOption {
                  type = types.nullOr types.port;
                  default = null;
                  description = "Service internal port";
                };
                extraConfig = mkOption {
                  type = types.lines;
                  default = ''
                    client_max_body_size 512M;
                  '';
                  description = "Extra nginx virtualHost configuration";
                };
                locations = mkOption {
                  type = types.attrsOf (
                    types.submodule {
                      options = {
                        proxyPass = mkOption {
                          type = types.str;
                          description = "Proxy pass URL";
                        };
                        proxyWebsockets = mkOption {
                          type = types.bool;
                          default = false;
                          description = "Enable WebSocket support";
                        };
                        extraConfig = mkOption {
                          type = types.lines;
                          default = "";
                          description = "Extra location configuration";
                        };
                      };
                    }
                  );
                  default = { };
                  description = "Additional nginx locations";
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

  # TODO: TLS + FQDN
  config = mkIf cfg.enable {

    # Reverse proxy
    services.nginx = {
      enable = mkForce true;

      # Configure virtual hosts
      virtualHosts = mkMerge (
        mapAttrsToList (
          name: srv:
          mkIf srv.nginx.manageVirtualHost {
            ${(mkDomainName name srv.domainName)} = {
              default = srv.nginx.defaultVirtualHost;
              inherit (srv.nginx) extraConfig;
              locations = mkMerge [

                # Default proxy location if proxyPort is set
                (mkIf (srv.nginx.proxyPort != null) {
                  "/" = {
                    proxyPass = "http://localhost:${toString srv.nginx.proxyPort}";
                  };
                })

                # Additional custom locations
                (mapAttrs (_: loc: {
                  inherit (loc) proxyPass;
                  inherit (loc) proxyWebsockets;
                  inherit (loc) extraConfig;
                }) srv.nginx.locations)
              ];
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

    # == WIP ==

    # Add services to homepage
    darkone.service.homepage.appServices =
      mkIf (!isGateway) (
        mapAttrsToList (name: srv: {
          ${(mkDisplayName name srv.displayName)} = mkIf srv.displayOnHomepage {
            description = mkDescription name srv.description;
            href = "http://${(mkDomainName name srv.domainName)}";
            icon = mkIcon name srv.icon;
          };
        }) enabledServices
      )
      // mkIf isGateway (
        map
          (srv: {
            ${(mkSrvValue srv "displayName")} = {
              description = (mkSrvValue srv "description") + " (" + srv.host + ")";
              href = "http://${(mkSrvValue srv "domainName")}";
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
