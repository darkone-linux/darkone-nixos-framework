# DNF reverse proxy: one Caddy vhost per resolved service, plus the HTTP(S)
# firewall of zone gateways and of the HCS.
#
# :::note[Exposure]
# - zone services: on the zone gateway, under the zone domain;
# - global services: on the HCS, under the network domain;
# - `external-hosts`: zone services the HCS fronts, proxied to their gateway.
# :::

{
  lib,
  config,
  host,
  zone,
  network,
  dnfLib,
  dnfConfig,
  workDir,
  ...
}:
let
  inherit (lib)
    any
    concatMapStringsSep
    concatStringsSep
    filter
    listToAttrs
    mkForce
    mkIf
    mkMerge
    optional
    optionalString
    ;
  cfg = config.darkone.system.services;
  inherit (cfg.resolved) services hasProtectedServices authHost;
  oauth2ProxyPort = toString dnfConfig.network.ports.oauth2Proxy;
  inLocalZone = dnfLib.inLocalZone zone;

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

  # Forward auth: checks auth on every request. When groups are supplied, the
  # `allowed_groups` query param restricts access to those Kanidm groups, so a
  # single oauth2-proxy can guard several services with distinct group policies.
  mkForwardAuth =
    allowedGroups:
    let

      # Kanidm emits groups in the `groups` claim as SPNs (`name@<domain>`), not
      # bare names, so match on the SPN. `@` is percent-encoded to keep it a
      # single Caddyfile token; oauth2-proxy decodes it back.
      spns = map (g: "${g}%40${network.domain}") allowedGroups;
      query = optionalString (allowedGroups != [ ]) "?allowed_groups=${concatStringsSep "," spns}";
    in
    ''
      forward_auth http://127.0.0.1:${oauth2ProxyPort} {
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

  # Bind internal IP for internal access services. `client_ip` (not `remote_ip`)
  # resolves the real client through trusted proxies (X-Forwarded-For), so a
  # request relayed by a trusted upstream is judged on the origin IP, not the
  # proxy's. `trusted_proxies` is set globally below.
  internalServiceBindSection = ''
    @external not client_ip private_ranges 100.64.0.0/10
    abort @external
  '';

  # Noise filter, not an access control: `User-Agent` is chosen by the caller,
  # so one header defeats the whole list. Kept for the log volume it removes;
  # never count it as a security measure in an audit.
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

  # The discovery documents clients actually resolve: they derive them from the
  # server_name (the apex), not from the matrix subdomain, which serves its own
  # copy of the very same payload.
  matrixWellKnownSection = dnfLib.mkMatrixWellKnown {
    inherit (network) domain;
    rtcFociUrl =
      if config.darkone.service.matrix.matrixRtc.enable then
        "https://matrix.${network.domain}/livekit/jwt"
      else
        null;
  };

  # Make virtualhost prefix:
  # - isInternal -> abort external access
  # - isProtected -> forward to oauth2-proxy (must be logged with kanidm + member of allowedGroups)
  mkPrefix =
    isInternal: isProtected: allowedGroups:
    (optionalString isInternal internalServiceBindSection)
    + (optionalString isProtected (mkForwardAuth allowedGroups));

  # A service can be turned into a virtualhost iff it is enabled and, when it
  # emits a `reverse_proxy` line, knows the backend port. Guarding on
  # servicePort alone would drop the pure-`extraConfig` vhosts
  # (hasReverseProxy = false), which legitimately have no port.
  hasUsableProxy = s: s.proxy.enable && (!s.proxy.hasReverseProxy || s.proxy.servicePort != null);

  # Global services to expose to internet, only for HCS
  globalServices = if isHcs then filter (s: s.params.global && hasUsableProxy s) services else [ ];

  # Extra configuration for global caddy section
  servicesExtraGlobalConfigs = map (s: s.proxy.extraGlobalConfig) services;

  # Hosts to expose in order to generate TLS certificates
  hostsForTls = if isHcs then zone.tls-builder-hosts else [ ];

  # Zone services exposed to the internet through the HCS. Each entry is
  # `{ fqdn; target; }` where `target` is the zone gateway tailnet IP the HCS
  # reverse-proxies to (see the generator's `external-hosts`).
  externalHosts = if isHcs then (zone.external-hosts or [ ]) else [ ];

  # `proxy.isInternal` binds a service to the LAN (abort external callers), so
  # exposing it to the internet via `externalAccess` is contradictory. Service
  # modules set `isInternal` unconditionally, so the HCS (where externalHosts is
  # populated) sees the real value for every service and can catch the clash.
  externalInternalConflicts = filter (
    s: s.proxy.isInternal && any (e: e.fqdn == s.params.fqdn) externalHosts
  ) services;

  # Full list of registered services for the local zone
  localZoneServices =
    if inLocalZone then filter (s: s.params.zone == zone.name && s.proxy.enable) services else [ ];

  # If current host is a gateway, open only internal interfaces
  isGateway = dnfLib.isGateway host zone;

  # Has service
  hasServicesToExpose =
    ((localZoneServices != [ ]) || (globalServices != [ ]) || (hostsForTls != [ ]))
    && (isGateway || isHcs);

  inherit (dnfLib.constants) caddyStorage;

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
  config = mkIf cfg.enable {

    # `proxy.isInternal` aborts external callers, `externalAccess` publishes
    # the service through the HCS: both at once is a contradiction.
    assertions = [
      {
        assertion = externalInternalConflicts == [ ];
        message = "darkone.system.services: internal-only services (proxy.isInternal) cannot be externalAccess: ${
          concatMapStringsSep ", " (s: s.name) externalInternalConflicts
        }.";
      }
    ];

    #--------------------------------------------------------------------------
    # Reverse proxy
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
      ''

      # Trust X-Forwarded-For from the tailnet + LAN so `client_ip` matchers
      # (see internalServiceBindSection) resolve the real origin behind the HCS
      # front. Only meaningful when there is a tailnet relaying requests.
      + optionalString hasHeadscale ''
        servers {
          trusted_proxies static private_ranges 100.64.0.0/10
        }
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
            isValid = hasUsableProxy srv;
            isDefault = isValid && srv.proxy.defaultService;
            backend = lib.optionalString srv.proxy.hasReverseProxy "reverse_proxy ${srv.proxy.scheme}://${srv.params.ip}:${toString srv.proxy.servicePort}";

            # The auth anchor (homepage) publicly exposes oauth2-proxy's endpoints.
            # `/oauth2/*` must stay unauthenticated, hence its own handle block.
            isAnchor = hasProtectedServices && authHost != null && srv.params.fqdn == authHost;
            oauth2Handle = optionalString isAnchor ''
              handle /oauth2/* {
                reverse_proxy http://127.0.0.1:${oauth2ProxyPort}
              }
            '';

            # Protected services wrap auth + backend in a catch-all handle so the
            # anchor's `/oauth2/*` handle is excluded from the forward-auth check.
            prefix = mkPrefix srv.proxy.isInternal srv.proxy.isProtected srv.proxy.allowedGroups;
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
            prefix = mkPrefix srv.proxy.isInternal srv.proxy.isProtected srv.proxy.allowedGroups;
            noRobots = optionalString srv.params.noRobots badBotsSection;
            reverseProxy = lib.optionalString srv.proxy.hasReverseProxy "reverse_proxy ${srv.proxy.scheme}://${srv.params.ip}:${toString srv.proxy.servicePort}";
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

        # Zone services exposed through the HCS: public TLS ends here, the whole
        # host (SSO included) is proxied to the zone gateway over the tailnet,
        # `Host` kept. `tls_server_name`: the gateway's on-demand TLS keys certs
        # by SNI and rejects a bare tailnet IP; under the FQDN it serves the
        # certificate synced from here, verified without skip-verify.
        ++ map (e: {
          "${e.fqdn}" = {
            logFormat = mkIf accessLogEnabled (mkLogFormat e.fqdn);
            extraConfig = ''
              reverse_proxy https://${e.target} {
                transport http {
                  tls_server_name {http.request.host}
                }
                header_up Host {host}
              }
            '';
          };
        }) externalHosts
      );
    };

    #--------------------------------------------------------------------------
    # Firewall
    #--------------------------------------------------------------------------

    networking.firewall = mkIf hasServicesToExpose {

      # The HCS serves the Internet on every interface.
      allowedTCPPorts = mkIf isHcs [
        80
        443
      ];

      interfaces = mkMerge [

        # Open HTTP port only for lan interface(s)
        (mkIf (isGateway && config.services.dnsmasq.enable) (
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
        ))

        # Let the HCS reach this gateway's reverse proxy over the tailnet to
        # front externally-exposed zone services (see externalHosts).
        (mkIf (isGateway && hasHeadscale) {
          ${config.services.tailscale.interfaceName}.allowedTCPPorts = [ 443 ];
        })
      ];
    };
  };
}

# TODO: See which reverse proxy needs this: {header_up Host {upstream_hostport}}
