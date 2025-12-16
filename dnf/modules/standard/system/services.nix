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
  hosts,
  zone,
  network,
  dnfLib,
  ...
}:
with lib;
let
  cfg = config.darkone.system.services;
  inLocalZone = zone.name != "www";
  hasHeadscale = network.coordination.enable;
  isHcs = (!inLocalZone) && hasHeadscale && network.coordination.hostname == host.hostname;

  # Build services list from real and default values
  services = map (service: {
    params = dnfLib.buildServiceParams (findFirst (
      h: h.hostname == service.host && h.zone == service.zone
    ) { } hosts) network service cfg.service.${service.name}.defaultParams;
    inherit (service) name;
    inherit (cfg.service.${service.name}) enable;
    inherit (cfg.service.${service.name}) displayOnHomepage;
    inherit (cfg.service.${service.name}) proxy;
  }) network.services;

  # Global services to expose to internet, only for HCS
  globalServices =
    if isHcs then (filter (s: (hasAttr "global" s.params) && s.params.global) services) else [ ];
  globalAddress = if isHcs then zone.address else [ ];

  # Full list of registered services for the local zone
  localZoneServices =
    if inLocalZone then filter (s: s.params.zone == zone.name && s.proxy.enable) services else [ ];

  # Has service
  hasServicesToExpose =
    ((localZoneServices != [ ]) || (globalServices != [ ]) || (globalAddress != [ ]))
    && (isGateway || isHcs);

  # Services to display on homepage dashboard
  homepageServices = filter (s: s.displayOnHomepage) services;

  # If current host is a gateway, open only internal interfaces
  isGateway =
    attrsets.hasAttrByPath [ "gateway" "hostname" ] zone && host.hostname == zone.gateway.hostname;

  # TODO: factorize with tailscale.nix
  caddyStorage = "/var/lib/caddy/storage";

  mkHomeSection =
    services:
    map (
      srv:
      let
        pubPriv = if srv.params.global then " 🔵" else ""; # " 🟡";
        mention = " (" + srv.params.zone + ":" + srv.params.host + ")" + pubPriv;
      in
      {
        ${srv.params.title} = mkIf srv.displayOnHomepage {
          description = srv.params.description + mention;
          inherit (srv.params) href;
          inherit (srv.params) icon;
        };
      }
    ) services;
in
{
  options = {
    darkone.system.services.enable = mkEnableOption "Enable DNF services manager to register and expose services";

    # Service registration options
    # TODO: implementation for "persist" files and dirs
    darkone.system.services.service = mkOption {
      default = { };
      description = "Global services configuration <name>";
      type = types.attrsOf (
        types.submodule (_: {
          options = {
            enable = mkEnableOption "Enable service proxy";
            # TODO: isPublic = mkEnableOption "Public service accessed from internet";

            defaultParams = mkOption {
              default = { };
              description = "Theses options are calculated by dnfLib.srv.extractServiceParams";
              type = types.submodule {
                options = {
                  domain = mkOption {
                    type = types.str;
                    default = "";
                    description = "Domain name for the service";
                  };
                  title = mkOption {
                    type = types.str;
                    default = "";
                    description = "Display name in homepage";
                  };
                  description = mkOption {
                    type = types.str;
                    default = "";
                    description = "Service description for homepage";
                  };
                  icon = mkOption {
                    type = types.str;
                    default = "";
                    description = "[Icon name for homepage](https://gethomepage.dev/configs/services/#icons)";
                  };
                  global = mkOption {
                    type = types.bool;
                    default = false;
                    description = "Global service is accessible on Internet";
                  };
                  noRobots = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Prevent robots from scanning if global is true";
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
            };

            # Homepage settings
            displayOnHomepage = mkOption {
              type = types.bool;
              default = true;
              description = "Display a link on homepage";
            };

            # Folders and files to persist
            persist.dirs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "/var/lib/immich" ];
              description = "Service persistant dirs";
            };
            persist.files = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Service persistant files";
            };
            persist.dbDirs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [ "/var/lib/postgresql" ];
              description = "Service persistant dirs with database(s)";
            };
            persist.dbFiles = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Service database file(s)";
            };
            persist.varDirs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [
                "/var/cache"
                "/var/log"
              ];
              description = "Variable secondary files (log, cache, etc.)";
            };
            persist.mediaDirs = mkOption {
              type = types.listOf types.str;
              default = [ ];
              example = [
                "/var/lib/immich/encoded-video"
                "/var/lib/immich/library"
                "/var/lib/immich/upload"
              ];
              description = "Service media dirs (pictures, videos, big files)";
            };

            # Reverse proxy settings
            proxy.enable = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to create virtualHost configuration (false for services that manage their own)";
            };
            proxy.defaultService = mkOption {
              type = types.bool;
              default = false;
              description = "Is the default service";
            };
            proxy.servicePort = mkOption {
              type = types.nullOr types.port;
              default = null;
              description = "Service internal port";
            };
            proxy.extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Extra caddy virtualHost configuration";
            };
            proxy.scheme = mkOption {
              type = types.str;
              default = "http";
              example = "https";
              description = "Internal service scheme (http / https)";
            };
          };
        })
      );
    };
  };

  config = mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Reverse proxy - Caddy
    #--------------------------------------------------------------------------

    services.caddy = mkIf hasServicesToExpose {
      enable = mkForce true;

      # Used by ACME, be sure to have a valid "admin@domain.tld" here.
      email = "admin@${network.domain}";

      # Fixed root file_system storage for sync
      globalConfig = ''
        storage file_system {
          root ${caddyStorage}
        }
      ''

      # Do not install certificates in local zone
      + optionalString inLocalZone ''
        skip_install_trust
      ''

      # No HTTPS redirection if no tailnet
      + optionalString (!hasHeadscale) ''
        auto_https off
      '';

      logFormat = "level INFO";

      # Configure virtual hosts (TODO: https + redir permanent)
      virtualHosts = mkMerge (
        map (
          srv:
          let
            isValid = srv.proxy.enable && (srv.proxy.servicePort != null);
            isDefault = isValid && srv.proxy.defaultService;
            vhPrefix = optionalString (!hasHeadscale) "http://";
            tls = optionalString (hasHeadscale && inLocalZone) ''
              tls {
                on_demand
              }
            '';
          in
          mkIf isValid {

            # Short name -> FQDN
            # "${vhPrefix}${srv.params.domain}" = mkIf inLocalZone {
            #   extraConfig = ''
            #     redir ${srv.params.href}{uri}
            #   '';
            # };

            # Reverse proxy to the target service
            "${vhPrefix}${srv.params.fqdn}" = {
              extraConfig = ''
                ${tls}reverse_proxy ${srv.proxy.scheme}://${srv.params.ip}:${toString srv.proxy.servicePort}
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
        ) localZoneServices

        # Global (public) services access on HCS
        ++ map (
          srv:
          let
            sPort = config.darkone.system.services.service.${srv.name}.proxy.servicePort;
            noRobots = lib.optionalString srv.params.noRobots ''
              @badbots {

                # Regular bots
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

                # Google / Bing / etc.
                header User-Agent "*Googlebot*"
                header User-Agent "*bingbot*"
                header User-Agent "*DuckDuckBot*"
                header User-Agent "*Baiduspider*"
                header User-Agent "*YandexBot*"

                # Suspect User-agents
                header User-Agent "*curl*"
                header User-Agent "*wget*"
                header User-Agent "*python*"
                header User-Agent "*Go-http-client*"

                # No User-Agent
                header User-Agent ""
              }
              handle @badbots {
                respond 403
              }
            '';
          in
          {
            "${srv.params.domain}.${network.domain}" = {
              extraConfig = noRobots + ''
                reverse_proxy ${srv.proxy.scheme}://${srv.params.ip}:${toString sPort}
                ${srv.proxy.extraConfig}
              '';
            };
          }
        ) globalServices

        # Internal FQDN to expose in order to sync TLS certificates
        ++ map (address: {
          "${address}" = {
            extraConfig = ''
              respond "${address}"
            '';
          };
        }) globalAddress
      );
    };

    #--------------------------------------------------------------------------
    # Homepage
    #--------------------------------------------------------------------------

    # Add services to homepage
    # TODO: widgets params integration in service params / sops
    darkone.service.homepage = mkIf isGateway {
      localServices = mkHomeSection (filter (srv: srv.params.zone == zone.name) homepageServices);
      remoteServices = mkHomeSection (filter (srv: srv.params.zone != zone.name) homepageServices);
    };

    #--------------------------------------------------------------------------
    # Firewall
    #--------------------------------------------------------------------------

    # Open right ports
    networking.firewall = mkIf hasServicesToExpose {

      # Open HTTP on all interfaces if not the gateway
      allowedTCPPorts = mkIf isHcs [
        80
        443
      ];

      # Open HTTP port only for lan interface(s)
      interfaces = mkIf (isGateway && config.services.dnsmasq.enable && hasServicesToExpose) (
        listToAttrs (
          map (iface: {
            name = iface;
            value = {
              allowedTCPPorts = [
                80
                443
              ];
            };
          }) config.services.dnsmasq.settings.interface
        )
      );
    };
  };
}

# TODO: Voir quel reverse proxy a besoin de ça : {header_up Host {upstream_hostport}}
