# DNF Service registration and configuration.
#
# :::caution[Special internal module]
# This module is used to register and configure DNF modules:
# - Coordination server client (headscale / tailscale)
# - Reverse proxies (caddy)
# - Homepage registrations
# - DNS entries
# - folders and files to backup
# :::

{
  lib,
  config,
  host,
  zone,
  network,
  ...
}:
with lib;
let
  cfg = config.darkone.system.services;
  inLocalZone = zone.name != "www";
  isHcs =
    (!inLocalZone) && network.coordination.enable && network.coordination.hostname == host.hostname;

  # Global services to expose to internet, only for HCS
  globalServices = if isHcs then zone.globalServices else [ ];

  # Full list of registered services in current host
  allServices = config.darkone.system.services.service;
  enabledServices = filterAttrs (_: v: v.enable) cfg.service;
  hasServices = (enabledServices != { }) || (globalServices != { });

  # Ports to open
  globalServicesPorts = mapAttrsToList (_: s: s.proxy.servicePort) (
    filterAttrs (_: s: (s.params.global && (s.proxy.servicePort != null))) enabledServices
  );

  # If not a gateway, open HTTP
  isGateway =
    attrsets.hasAttrByPath [ "gateway" "hostname" ] zone && host.hostname == zone.gateway.hostname;

  # Shared services parameters
  mkSrvValue =
    srv: key:
    if hasAttrByPath [ "params" key ] srv then
      srv.params.${key}
    else
      allServices.${srv.service}.params.${key};
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
              # TODO: isPublic = mkEnableOption "Public service accessed from internet";

              params = mkOption {
                type = lib.types.submodule {
                  options = {
                    domain = mkOption {
                      type = types.str;
                      default = name;
                      description = "Domain name for the service";
                    };
                    title = mkOption {
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
                    global = mkOption {
                      type = types.bool;
                      default = false;
                      description = "Global service is accessible on Internet";
                    };
                    fqdn = mkOption {
                      type = types.str;
                      default = "";
                      description = "Calculated FQDN or the service before the reverse proxy";
                    };
                    href = mkOption {
                      type = types.str;
                      default = "";
                      description = "Calculated URL of the service before the reverse proxy";
                    };
                    ip = mkOption {
                      type = types.str;
                      default = "";
                      description = "Calculated IP to contact the service";
                    };
                  };
                };
                default = { };
                description = "Theses options are calculated by dnfLib.srv.extractServiceParams";
              };

              # Homepage settings
              displayOnHomepage = mkOption {
                type = types.bool;
                default = true;
                description = "Display a link on homepage";
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

    #--------------------------------------------------------------------------
    # Wildcard keys
    #--------------------------------------------------------------------------

    # TLS wildcard keys
    sops.secrets.tls-crt = {
      mode = "0400";
      owner = "caddy";
    };
    sops.secrets.tls-key = {
      mode = "0400";
      owner = "caddy";
    };

    #--------------------------------------------------------------------------
    # Reverse proxy
    #--------------------------------------------------------------------------

    services.caddy = {
      enable = mkForce true;

      # TMP
      globalConfig = lib.mkIf inLocalZone ''
        auto_https off
      '';

      logFormat = lib.mkIf (!inLocalZone) (lib.mkForce "level INFO");

      # Configure virtual hosts (TODO: https + redir permanent)
      # TODO: TLS -> les sous-sous-domaines ne sont pas couverts par wildcards :(
      virtualHosts = mkMerge (
        mapAttrsToList (
          _name: srv:
          let
            isValid = srv.proxy.enable && (srv.proxy.servicePort != null);
            isDefault = isValid && srv.proxy.defaultService;
            isInsecure = inLocalZone && (!srv.params.global);
            vhPrefix = if isInsecure then "http://" else "";
            tls =
              if isInsecure then
                ""
              else
                ''
                  tls ${config.sops.secrets.tls-crt.path} ${config.sops.secrets.tls-key.path}
                '';
          in
          mkIf isValid {

            # Short name -> FQDN
            "${vhPrefix}${srv.params.domain}" = {
              extraConfig = ''
                redir ${srv.params.href}{uri}
              '';
            };

            # Reverse proxy to the target service
            "${vhPrefix}${srv.params.fqdn}" = {
              extraConfig = ''
                ${tls}reverse_proxy http://${srv.params.ip}:${toString srv.proxy.servicePort}
                ${srv.proxy.extraConfig}
              '';
            };

            # Redirection to default domain if needed
            ":80, :443" = mkIf isDefault {
              extraConfig = ''
                redir ${srv.params.href}
              '';
            };
          }
        ) enabledServices

        # Global (public) services access
        ++ map (
          s:
          let
            sPort = config.darkone.system.services.service.${s.service}.proxy.servicePort;
          in
          {
            "${s.domain}.${network.domain}" = {
              extraConfig = ''
                @badbots {

                  # Bots "classiques"
                  header User-Agent "*bot*"
                  header User-Agent "*crawler*"
                  header User-Agent "*spider*"
                  header User-Agent "*scan*"
                  header User-Agent "*fetch*"

                  # Bot SEO
                  header User-Agent "*AhrefsBot*"
                  header User-Agent "*SemrushBot*"
                  header User-Agent "*MJ12bot*"
                  header User-Agent "*DotBot*"

                  # Google / Bing / etc. (si tu veux VRAIMENT tout bloquer)
                  header User-Agent "*Googlebot*"
                  header User-Agent "*bingbot*"
                  header User-Agent "*DuckDuckBot*"
                  header User-Agent "*Baiduspider*"
                  header User-Agent "*YandexBot*"

                  # User-agents suspects
                  header User-Agent "*curl*"
                  header User-Agent "*wget*"
                  header User-Agent "*python*"
                  header User-Agent "*Go-http-client*"

                  # User-Agent vide
                  header User-Agent ""
                }
                handle @badbots {
                  respond 403
                }
                tls ${config.sops.secrets.tls-pem.path} ${config.sops.secrets.tls-key.path}
                reverse_proxy http://${s.targetIp}:${toString sPort}
              '';
            };
          }
        ) globalServices
      );
    };

    #--------------------------------------------------------------------------
    # Homepage
    #--------------------------------------------------------------------------

    # Add services to homepage (TODO: public or not)
    darkone.service.homepage.appServices =
      mkIf (!isGateway) (
        mapAttrsToList (_name: srv: {
          ${srv.params.title} = mkIf srv.displayOnHomepage {
            inherit (srv.params) description;
            inherit (srv.params) href;
            inherit (srv.params) icon;
          };
        }) enabledServices
      )
      // mkIf isGateway (
        map
          (srv: {
            ${(mkSrvValue srv "title")} = {
              description = (mkSrvValue srv "description") + " (" + srv.host + ")";
              href = mkSrvValue srv "href";
              icon = mkSrvValue srv "icon";
            };
          })
          (
            builtins.filter (
              srv: (hasAttr srv.service allServices) && allServices.${srv.service}.displayOnHomepage
            ) zone.sharedServices
          )
      );

    #--------------------------------------------------------------------------
    # DNS
    #--------------------------------------------------------------------------

    # Add domains to /etc/hosts (deprecated?)
    networking.hosts = mkMerge (
      mapAttrsToList (
        _name: srv: mkIf config.services.dnsmasq.enable { "${host.ip}" = [ srv.params.domain ]; }
      ) enabledServices
    );

    #--------------------------------------------------------------------------
    # Firewall
    #--------------------------------------------------------------------------

    # Open right ports
    networking.firewall = lib.mkIf hasServices {

      # Open HTTP on all interfaces if not the gateway
      allowedTCPPorts = lib.mkIf (!isGateway) (
        [
          80
          443
        ]
        ++ globalServicesPorts
      );

      # Open HTTP port only for lan interface(s)
      # TODO: simplify + adapt to headscale
      interfaces = mkIf (isGateway && config.services.dnsmasq.enable) (
        lib.listToAttrs (
          map (iface: {
            name = iface;
            value = {
              allowedTCPPorts = [
                80
                443
              ]
              ++ globalServicesPorts;
            };
          }) config.services.dnsmasq.settings.interface
        )
      );
    };
  };
}

# TODO: Voir quel reverse proxy a besoin de ça : {header_up Host {upstream_hostport}}
