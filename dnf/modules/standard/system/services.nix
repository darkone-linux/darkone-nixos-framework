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
  inLocalZone = dnfLib.inLocalZone zone;
  hasHeadscale = network.coordination.enable;
  isHcs = dnfLib.isHcs host zone network;

  # Has a Kanidm client on the same server (HCS or main gateway)
  # -> Redirect to IDM from the main domain.
  hasIdmClient = config.services.kanidm.enableClient;

  # Has matrix server (synapse) on the same server.
  # -> Add a well-known url to the main domain.
  hasMatrix = config.services.matrix-synapse.enable;

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

  # Need Oauth2 proxy if has protected service
  hasProtectedServices = any (s: s.proxy.isProtected) services;

  # Forward auth : vérifie l'auth à chaque requête
  protectedServiceForwardSection = ''
    forward_auth http://127.0.0.1:4180 {
      uri /oauth2/auth
      copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Groups
    }
  '';

  # Bind internal IP for internal access services
  internalServiceBindSection = ''
    @external not remote_ip private_ranges 100.64.0.0/10
    abort @external
  '';

  badBotsSection = ''
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

      # Used by Maelie
      #header User-Agent "*python*"

      # This one is used by forgejo!
      #header User-Agent "*Go-http-client*"

      # No User-Agent
      header User-Agent ""
    }
    handle @badbots {
      respond 403
    }
  '';

  matrixWellKnownSection = ''
    handle /.well-known/matrix/client {
      header Access-Control-Allow-Origin "*"
      header Content-Type "application/json"
      respond `{"m.homeserver":{"base_url":"https://matrix.${network.domain}"}}`
    }
    handle /.well-known/matrix/server {
      header Access-Control-Allow-Origin "*"
      header Content-Type "application/json"
      respond `{"m.server":"matrix.${network.domain}:443"}`
    }
  '';

  # Make virtualhost prefix
  mkPrefix =
    isInternal: isProtected:
    (optionalString isInternal internalServiceBindSection)
    + (optionalString isProtected protectedServiceForwardSection);

  # Global services to expose to internet, only for HCS
  globalServices =
    if isHcs then (filter (s: (hasAttr "global" s.params) && s.params.global) services) else [ ];

  # Extra configuration for global caddy section
  servicesExtraGlobalConfigs = map (s: s.proxy.extraGlobalConfig) services;

  # Hosts to expose in order to generate TLS certificates
  hostsForTls = if isHcs then zone.tls-builder-hosts else [ ];

  # Full list of registered services for the local zone
  localZoneServices =
    if inLocalZone then filter (s: s.params.zone == zone.name && s.proxy.enable) services else [ ];

  # If current host is a gateway, open only internal interfaces
  isGateway = dnfLib.isGateway host zone;

  # Has service
  hasServicesToExpose =
    ((localZoneServices != [ ]) || (globalServices != [ ]) || (hostsForTls != [ ]))
    && (isGateway || isHcs);

  # Services to display on homepage dashboard
  homepageServices = filter (s: s.displayOnHomepage) services;

  # TODO: factorize with tailscale.nix
  caddyStorage = "/var/lib/caddy/storage";

  mkHomeSection =
    services:
    map (
      srv:
      let
        pubPriv =
          if srv.params.global then
            (if srv.params.zone == "www" then "🟢" else "🟡")
          else
            (if srv.params.zone == zone.name then "🔵" else "🟠");
        mention = " (" + srv.params.zone + ":" + srv.params.host + ")";
      in
      {
        "${srv.params.title}" = mkIf srv.displayOnHomepage {
          description = srv.params.description + mention + " " + pubPriv;
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
    darkone.system.services.service = mkOption {
      default = { };
      description = "Global services configuration <name>";
      type = types.attrsOf (
        types.submodule (_: {
          options = {
            enable = mkEnableOption "Enable service proxy";
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
                    description = "[Icon name for homepage](https://selfh.st/icons/)";
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
              example = [ config.services.postgresql.dataDir ];
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
            proxy.isProtected = mkOption {
              type = types.bool;
              default = false;
              description = "Oauth2 protected service";
            };
            proxy.isInternal = mkOption {
              type = types.bool;
              default = false;
              description = "Bind service on internal interface only (not internet accessible)";
            };
            proxy.hasReverseProxy = mkOption {
              type = types.bool;
              default = true;
              description = "This is a reverse proxy (or another virtualhost configuration via extraConfig)";
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
            proxy.preExtraConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Extra caddy virtualHost configuration (prefix)";
            };
            proxy.extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Extra caddy virtualHost configuration";
            };
            proxy.extraGlobalConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Extra caddy configuration";
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

      # Extra global config from services
      extraConfig = concatStringsSep "\n" servicesExtraGlobalConfigs;

      logFormat = "level ERROR"; # INFO

      # Configure virtual hosts (TODO: https + redir permanent)
      virtualHosts = mkMerge (

        # Main domain root virtualhost on HCS
        optional isHcs {
          ${network.domain} =
            let
              matrixWellKnown = optionalString hasMatrix matrixWellKnownSection;
              mainAction =

                # On encapsule dans un "handle" pour que le challenge fonctionne, sinon
                # le handle automatique pour let's encrypt ne fonctionne pas.
                if hasIdmClient then
                  ''
                    handle {
                      redir / https://idm.${network.domain}
                    }
                  ''
                else
                  "respond \"Welcome to ${network.domain}\"";
            in
            {
              extraConfig = ''
                ${matrixWellKnown}
                ${mainAction}
              '';
            };
        }

        # Oauth2 proxy
        # Expose oauth2-proxy publiquement (paths /oauth2/*)
        # TODO: zonable proxy
        ++ optional hasProtectedServices {
          "auth.${network.domain}" = {
            extraConfig = ''
              route /oauth2/* {
                uri strip_prefix /oauth2
                reverse_proxy http://127.0.0.1:4180
              }
              redir / /oauth2/sign_in
            '';
          };
        }

        # Local services virtualhosts
        ++ map (
          srv:
          let
            isValid = srv.proxy.enable && (srv.proxy.servicePort != null);
            isDefault = isValid && srv.proxy.defaultService;
            prefix = mkPrefix srv.proxy.isInternal srv.proxy.isProtected;
            vhPrefix = optionalString (!hasHeadscale) "http://";
            tls = optionalString (hasHeadscale && inLocalZone) ''
              tls {
                on_demand
              }
            '';
            reverseProxy = lib.optionalString srv.proxy.hasReverseProxy "${tls}reverse_proxy ${srv.proxy.scheme}://${srv.params.ip}:${toString srv.proxy.servicePort}";
          in
          mkIf isValid {

            # Reverse proxy to the target service
            "${vhPrefix}${srv.params.fqdn}" = {
              extraConfig = dnfLib.cleanString ''
                ${prefix}
                ${srv.proxy.preExtraConfig}
                ${reverseProxy}
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
        # TODO: Accès privé / réservé pour idm.domain.tld
        ++ map (
          srv:
          let
            sPort = config.darkone.system.services.service.${srv.name}.proxy.servicePort;
            prefix = mkPrefix srv.proxy.isInternal srv.proxy.isProtected;
            noRobots = optionalString srv.params.noRobots badBotsSection;
            reverseProxy = lib.optionalString srv.proxy.hasReverseProxy "reverse_proxy ${srv.proxy.scheme}://${srv.params.ip}:${toString sPort}";
          in
          {
            "${srv.params.domain}.${network.domain}" = {
              extraConfig = dnfLib.cleanString ''
                ${noRobots}
                ${prefix}
                ${srv.proxy.preExtraConfig}
                ${reverseProxy}
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
        }) hostsForTls
      );
    };

    #--------------------------------------------------------------------------
    # Oauth2-proxy (protected services)
    #--------------------------------------------------------------------------

    # TODO: zonable proxy

    sops.secrets.oidc-secret-internal-service = mkIf hasProtectedServices {
      mode = "0400";
      owner = "oauth2-proxy";
      key = "oidc-secret-internal";
    };
    sops.secrets.oauth2-proxy-cookie-internal-service = mkIf hasProtectedServices {
      mode = "0400";
      owner = "oauth2-proxy";
    };

    sops.secrets.oidc-secret-internal = mkIf hasProtectedServices { };
    sops.templates."oauth2-proxy-keyfile" = mkIf hasProtectedServices {
      mode = "0400";
      owner = "oauth2-proxy";
      content = ''
        OAUTH2_PROXY_CLIENT_SECRET=${config.sops.placeholder.oidc-secret-internal}
      '';
    };

    services.oauth2-proxy = mkIf hasProtectedServices {
      enable = true;
      httpAddress = "127.0.0.1:4180"; # Écoute locale seulement
      provider = "oidc";
      oidcIssuerUrl = "https://idm.${network.domain}/oauth2/openid/internal-service";
      clientID = "internal-service";
      keyFile = config.sops.templates.postfix-sasl-password.path;
      redirectURL = "https://auth.${network.domain}/oauth2/callback"; # Doit matcher Kanidm
      scope = "openid email";
      cookie = {
        #secretFile = config.sops.secrets.oauth2-proxy-cookie-internal-service.path;
        #domain = ".${network.domain}"; # Pour partager le cookie entre sous-domaines
        secure = true;
      };

      setXauthrequest = true; # Envoie X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Groups
      passAccessToken = false; # Optionnel : passe le token aux upstreams
      reverseProxy = true; # Important pour forward_auth

      upstream = [ "static://200" ]; # Répond 200 OK après auth (mode forward_auth)
      extraConfig = {
        allowed-group = [ "admins" ];
        client-secret-file = config.sops.secrets.oidc-secret-internal-service.path;
        cookie-secret-file = config.sops.secrets.oauth2-proxy-cookie-internal-service.path;
        skip-provider-button = true; # Directement vers Kanidm
        email-domain = "*"; # Accepte tous les emails
      };
    };

    #--------------------------------------------------------------------------
    # Homepage
    #--------------------------------------------------------------------------

    # Add services to homepage
    # TODO: widgets params integration in service params / sops
    darkone.service.homepage = mkIf isGateway {
      localServices = mkHomeSection (
        filter (srv: srv.params.zone == zone.name && !srv.params.global) homepageServices
      );
      globalServices = mkHomeSection (filter (srv: srv.params.global) homepageServices);
      remoteServices = mkHomeSection (
        filter (srv: srv.params.zone != zone.name && !srv.params.global) homepageServices
      );
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
