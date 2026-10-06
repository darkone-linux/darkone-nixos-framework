# DNF SSO: oauth2-proxy in front of the protected services of a zone, backed
# by the Kanidm `internal-service` OAuth2 client.
#
# :::note[Flow]
# Caddy `forward_auth` checks every request against `/oauth2/auth` (cf.
# `caddy.nix`). The login flow is anchored on the zone homepage FQDN, which
# hosts oauth2-proxy's public `/oauth2/*` endpoints; a cookie scoped to the
# zone domain keeps the session across its services.
# :::

{
  lib,
  pkgs,
  config,
  zone,
  network,
  dnfLib,
  dnfConfig,
  ...
}:
let
  inherit (lib) mkIf mkMerge;
  cfg = config.darkone.system.services;
  inherit (cfg.resolved) hasProtectedServices authHost;
  inLocalZone = dnfLib.inLocalZone zone;

  # oauth2-proxy is served per gateway: local zones answer on their own domain,
  # only the HCS answers on the network domain.
  authDomain = if inLocalZone then zone.domain else network.domain;

  # Kanidm OIDC issuer backing oauth2-proxy. Single source: both the service
  # config and the start-up readiness gate (below) derive from it.
  oidcIssuerUrl = "https://idm.${network.domain}/oauth2/openid/internal-service";
in
{
  config = mkIf cfg.enable (mkMerge [
    {

      # Protected services anchor their login flow on the homepage FQDN, so the
      # homepage service must be present in any zone that protects a service.
      assertions = [
        {
          assertion = !hasProtectedServices || authHost != null;
          message = "darkone.system.services: a protected service requires the homepage service (auth anchor) enabled in the same zone.";
        }
      ];
    }

    (mkIf hasProtectedServices {

      # OAuth2 client secret, shared with the kanidm-side `internal-service`
      # provisioning (idm.nix declares the same `oidc-secret-internal` source).
      sops.secrets.oidc-secret-internal-service = {
        mode = "0400";
        owner = "oauth2-proxy";
        key = "oidc-secret-internal";
      };

      # Session cookie encryption key (32 URL-safe base64 bytes, generated).
      sops.secrets.oauth2-proxy-cookie-internal-service = {
        mode = "0400";
        owner = "oauth2-proxy";
      };

      services.oauth2-proxy = {
        enable = true;
        httpAddress = "127.0.0.1:${toString dnfConfig.network.ports.oauth2Proxy}"; # Local listen only
        provider = "oidc";
        inherit oidcIssuerUrl;
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

        # In reverseProxy mode oauth2-proxy trusts X-Forwarded-* from every source
        # by default (0.0.0.0/0). The proxy only listens on loopback (httpAddress
        # above) and Caddy, on the same host, is its sole client, so restrict the
        # trust to the loopback to reject forwarded-header spoofing.
        trustedProxyIP = [
          "127.0.0.1/32"
          "::1/128"
        ];

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

      # Harden the proxy against a momentarily unreachable OIDC issuer (kanidm on
      # hcs), typical right after an hcs rebuild: gate the start until kanidm is
      # reachable, and never latch failed, so the proxy self-heals without a manual
      # redeploy.
      systemd.services.oauth2-proxy = {

        # Disable the start-rate limiter and pace retries: with the default 100ms
        # RestartSec the proxy burns its 5-restart budget in under a second and
        # gives up with start-limit-hit; here it retries every 10s until kanidm is
        # back.
        startLimitIntervalSec = 0;
        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";

          # The gate below may legitimately wait its whole loop; keep this above it
          # so systemd does not SIGTERM it as a start-pre timeout.
          TimeoutStartSec = "150s";

          # Readiness gate: wait until kanidm answers the discovery URL *at all*.
          # Any HTTP status means reachable — kanidm 403s an unauthenticated GET,
          # yet the daemon's own discovery still succeeds; only a connection failure
          # (curl prints 000) keeps us waiting. Best-effort: on timeout we start
          # anyway and rely on Restart above. Keeps the common case a clean first
          # start (no failed flap, no SystemdUnitFailed noise).
          ExecStartPre = pkgs.writeShellScript "oauth2-proxy-wait-issuer" ''
            url="${oidcIssuerUrl}/.well-known/openid-configuration"
            for _ in $(${pkgs.coreutils}/bin/seq 1 15); do
              code=$(${pkgs.curl}/bin/curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "$url" || true)
              [ -n "$code" ] && [ "$code" != "000" ] && exit 0
              ${pkgs.coreutils}/bin/sleep 3
            done
            echo "oauth2-proxy: issuer unreachable after ~100s, starting anyway" >&2
            exit 0
          '';
        };
      };
    })
  ]);
}
