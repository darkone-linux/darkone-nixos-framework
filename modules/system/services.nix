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
  workDir,
  ...
}:
with lib;
let
  cfg = config.darkone.system.services;
  inLocalZone = dnfLib.inLocalZone zone;

  # oauth2-proxy is served per gateway: local zones answer on their own domain,
  # only the HCS answers on the network domain.
  authDomain = if inLocalZone then zone.domain else network.domain;

  # On-demand TLS for local-zone vhosts: a local zone has no public ACME, so
  # Caddy fetches certs lazily per SNI. Shared by the service and auth vhosts.
  localTls = optionalString (hasHeadscale && inLocalZone) ''
    tls {
      on_demand
    }
  '';

  # vhosts are plain HTTP when there is no tailnet (auto-HTTPS is off).
  vhPrefix = optionalString (!hasHeadscale) "http://";
  hasHeadscale = network.coordination.enable;
  isHcs = dnfLib.isHcs host zone network;

  # Has a Kanidm client on the same server (HCS or main gateway)
  # -> Redirect to IDM from the main domain.
  hasIdmClient = config.services.kanidm.client.enable;

  # Has matrix server (synapse) on the same server.
  # -> Add a well-known url to the main domain.
  hasMatrix = config.services.matrix-synapse.enable;

  # Build services list from real and default values
  services = map (service: {
    params = dnfLib.buildServiceParams (dnfLib.findHost service.host service.zone
      hosts
    ) network service cfg.service.${service.name}.defaultParams;
    inherit (service) name;
    inherit (cfg.service.${service.name}) enable;
    inherit (cfg.service.${service.name}) displayOnHomepage;
    inherit (cfg.service.${service.name}) proxy;
  }) network.services;

  # Need Oauth2 proxy if has protected service
  hasProtectedServices = any (s: s.proxy.isProtected) services;

  # Single auth anchor per zone: oauth2-proxy's public `/oauth2/*` endpoints are
  # hosted on the homepage FQDN, which already has a provisioned TLS certificate.
  # This avoids a synthetic `auth.<zone>` host (no cert in the HCS->gateway sync).
  # Every protected service sends the login flow here; the shared `.<zone>` cookie
  # keeps SSO across services.
  authAnchor = findFirst (s: s.name == "homepage") null services;
  authHost = if authAnchor != null then authAnchor.params.fqdn else null;

  # Forward auth: checks auth on every request. When groups are supplied, the
  # `allowed_groups` query param restricts access to those Kanidm groups, so a
  # single oauth2-proxy can guard several services with distinct group policies.
  mkForwardAuth =
    allowedGroups: externalOnly:
    let

      # Kanidm emits groups in the `groups` claim as SPNs (`name@<domain>`), not
      # bare names, so match on the SPN. `@` is percent-encoded to keep it a
      # single Caddyfile token; oauth2-proxy decodes it back.
      spns = map (g: "${g}%40${network.domain}") allowedGroups;
      query = optionalString (allowedGroups != [ ]) "?allowed_groups=${concatStringsSep "," spns}";

      # When externalOnly, gate the auth on a matcher so internal callers (LAN
      # private ranges + tailnet) reach the backend without logging in; only
      # external clients are challenged. Otherwise the auth applies to everyone.
      extMatcher = optionalString externalOnly ''
        @external not remote_ip private_ranges 100.64.0.0/10
      '';
      authGuard = optionalString externalOnly "@external ";
    in
    ''
      ${extMatcher}forward_auth ${authGuard}http://127.0.0.1:4180 {
        uri /oauth2/auth${query}
        copy_headers X-Auth-Request-User X-Auth-Request-Email X-Auth-Request-Groups

        # /oauth2/auth answers 401 when unauthenticated; turn that into a
        # browser redirect to the login flow instead of a bare 401. `rd` brings
        # the user back to the original URL after login (cross-subdomain, hence
        # oauth2-proxy's whitelist-domain).
        @unauthenticated status 401
        handle_response @unauthenticated {
          redir * https://${authHost}/oauth2/start?rd=https://{http.request.host}{http.request.uri}
        }
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
    isInternal: isProtected: allowedGroups: externalOnly:
    (optionalString isInternal internalServiceBindSection)
    + (optionalString isProtected (mkForwardAuth allowedGroups externalOnly));

  # Global services to expose to internet, only for HCS
  globalServices =
    if isHcs then
      (filter (s: (hasAttr "global" s.params) && s.params.global && s.proxy.enable) services)
    else
      [ ];

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

  inherit (dnfLib.constants) caddyStorage;

  mkHomeSection = dnfLib.mkHomepageSection zone.name;

  # Caddy access logs in JSON for Alloy/Loki ingestion.
  #
  # The NixOS Caddy module exposes a `logFormat` option per vhost that defaults
  # to `output file /var/log/caddy/access-<hostName>.log` in text format.
  # When Loki is active, we override it to produce JSON + rotation.
  # Otherwise we leave the default intact (a single `log` block is generated, in text).
  accessLogEnabled = config.darkone.service.loki.isClient or false;
  mkLogFormat = hostName: ''
    output file /var/log/caddy/access-${hostName}.log {
      roll_size 50MiB
      roll_keep 5
    }
    format json
  '';
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

            # Network/DNS topology hints consumed by the generator (nix eval ->
            # var/generated/service-registry.json). Kept here so a service is
            # fully described in its own module: the generator no longer hard-codes
            # any service name. These describe the DNS view, distinct from the
            # `proxy.*` options below which describe the Caddy view.
            reverseProxy = mkOption {
              type = types.bool;
              default = true;
              description = "Reached through the zone gateway reverse proxy (DNS points to the gateway LAN IP)";
            };
            uniquePerZone = mkOption {
              type = types.bool;
              default = false;
              description = "At most one instance allowed per zone (generator validation)";
            };
            externalAccess = mkOption {
              type = types.bool;
              default = false;
              description = "www-zone service reachable from the LAN via a fixed host IP (e.g. headscale, turn)";
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
            proxy.allowedGroups = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "Kanidm groups allowed on this protected service (empty = any authenticated user)";
            };
            proxy.protectExternalOnly = mkOption {
              type = types.bool;
              default = false;
              description = "Only require auth for external clients; internal LAN/tailnet callers bypass the login";
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

    # Protected services anchor their login flow on the homepage FQDN, so the
    # homepage service must be present in any zone that protects a service.
    assertions = [
      {
        assertion = !hasProtectedServices || authHost != null;
        message = "darkone.system.services: a protected service requires the homepage service (auth anchor) enabled in the same zone.";
      }
    ];

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
              localPath = workDir + "/usr/www/public";
              staticDirExists = builtins.pathExists localPath;
              matrixWellKnown = optionalString hasMatrix matrixWellKnownSection;
              mainAction =

                # If static files exist in usr/www/public, serve them from the store.
                # Otherwise redirect to IDM.
                if staticDirExists then
                  ''
                    handle {
                      root * ${localPath}
                      file_server
                    }
                  ''

                # Wrap in a "handle" block so the challenge works, otherwise
                # the automatic let's encrypt handle does not work.
                else if hasIdmClient then
                  ''
                    handle {
                      redir / https://idm.${network.domain}
                    }
                  ''
                else
                  "respond \"Welcome to ${network.domain}\"";
            in
            {
              logFormat = mkIf accessLogEnabled (mkLogFormat network.domain);
              extraConfig = ''
                ${matrixWellKnown}
                ${mainAction}
              '';
            };
        }

        # Local services virtualhosts
        ++ map (
          srv:
          let
            isValid = srv.proxy.enable && (srv.proxy.servicePort != null);
            isDefault = isValid && srv.proxy.defaultService;
            backend = lib.optionalString srv.proxy.hasReverseProxy "reverse_proxy ${srv.proxy.scheme}://${srv.params.ip}:${toString srv.proxy.servicePort}";

            # The auth anchor (homepage) publicly exposes oauth2-proxy's endpoints.
            # `/oauth2/*` must stay unauthenticated, hence its own handle block.
            isAnchor = hasProtectedServices && authHost != null && srv.params.fqdn == authHost;
            oauth2Handle = optionalString isAnchor ''
              handle /oauth2/* {
                reverse_proxy http://127.0.0.1:4180
              }
            '';

            # Protected services wrap auth + backend in a catch-all handle so the
            # anchor's `/oauth2/*` handle is excluded from the forward-auth check.
            prefix =
              mkPrefix srv.proxy.isInternal srv.proxy.isProtected srv.proxy.allowedGroups
                srv.proxy.protectExternalOnly;
            body =
              if srv.proxy.isProtected then
                ''
                  handle {
                    ${prefix}
                    ${srv.proxy.preExtraConfig}
                    ${backend}
                    ${srv.proxy.extraConfig}
                  }
                ''
              else
                ''
                  ${srv.proxy.preExtraConfig}
                  ${backend}
                  ${srv.proxy.extraConfig}
                '';
          in
          mkIf isValid {

            # Reverse proxy to the target service
            "${vhPrefix}${srv.params.fqdn}" = {
              logFormat = mkIf accessLogEnabled (mkLogFormat srv.params.fqdn);
              extraConfig = dnfLib.cleanString ''
                ${localTls}
                ${oauth2Handle}
                ${body}
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
        # TODO: Private / restricted access for idm.domain.tld
        ++ map (
          srv:
          let
            sPort = config.darkone.system.services.service.${srv.name}.proxy.servicePort;
            prefix =
              mkPrefix srv.proxy.isInternal srv.proxy.isProtected srv.proxy.allowedGroups
                srv.proxy.protectExternalOnly;
            noRobots = optionalString srv.params.noRobots badBotsSection;
            reverseProxy = lib.optionalString srv.proxy.hasReverseProxy "reverse_proxy ${srv.proxy.scheme}://${srv.params.ip}:${toString sPort}";
          in
          {
            "${srv.params.domain}.${network.domain}" = {
              logFormat = mkIf accessLogEnabled (mkLogFormat "${srv.params.domain}.${network.domain}");
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

    # OAuth2 client secret, shared with the kanidm-side `internal-service`
    # provisioning (idm.nix declares the same `oidc-secret-internal` source).
    sops.secrets.oidc-secret-internal-service = mkIf hasProtectedServices {
      mode = "0400";
      owner = "oauth2-proxy";
      key = "oidc-secret-internal";
    };

    # Session cookie encryption key (32-byte base64, consumer-provided).
    sops.secrets.oauth2-proxy-cookie-internal-service = mkIf hasProtectedServices {
      mode = "0400";
      owner = "oauth2-proxy";
    };

    services.oauth2-proxy = mkIf hasProtectedServices {
      enable = true;
      httpAddress = "127.0.0.1:4180"; # Local listen only
      provider = "oidc";
      oidcIssuerUrl = "https://idm.${network.domain}/oauth2/openid/internal-service";
      clientID = "internal-service";
      redirectURL = "https://${authHost}/oauth2/callback"; # Must match Kanidm
      scope = "openid email groups"; # `groups` is required for allowed_groups
      cookie = {
        secretFile = config.sops.secrets.oauth2-proxy-cookie-internal-service.path;

        # Share the session across the zone's subdomains (SSO).
        domain = ".${authDomain}";
        secure = true;
      };

      setXauthrequest = true; # Forwards X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Groups
      passAccessToken = false; # Optional: pass token to upstreams
      reverseProxy = true; # Important for forward_auth

      upstream = [ "static://200" ]; # Reply 200 OK after auth (forward_auth mode)

      # Per-service authorization is enforced by Caddy via the `allowed_groups`
      # query param (see mkForwardAuth); the proxy itself only authenticates.
      extraConfig = {
        client-secret-file = config.sops.secrets.oidc-secret-internal-service.path;
        code-challenge-method = "S256"; # Kanidm requires PKCE
        skip-provider-button = true; # Straight to Kanidm
        email-domain = "*"; # Accept all emails

        # Allow the post-login `rd` redirect back to sibling subdomains of the
        # zone (the anchor hosts /oauth2 on homepage.<zone>, other protected
        # services live on their own <svc>.<zone>).
        whitelist-domain = ".${authDomain}";
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

# TODO: See which reverse proxy needs this: {header_up Host {upstream_hostport}}
