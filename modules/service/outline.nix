# A full-configured outline wiki.
#
# Sign-in through Kanidm (OIDC), PKCE enforced.
#
# :::caution[IdM needed at startup]
# Outline reads the Kanidm discovery document once, when it starts, and exits
# if it cannot: the unit waits up to ~100s for the IdM, then systemd retries.
# :::

{
  lib,
  pkgs,
  dnfLib,
  dnfConfig,
  config,
  network,
  zone,
  host,
  hosts,
  ...
}:
let
  cfg = config.darkone.service.outline;
  srvPort = dnfConfig.network.ports.outline;
  params = dnfLib.extractServiceParams host network "outline" { };
  inherit
    (dnfLib.mkOidcContext {
      name = "outline";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;

  # Discovery is fetched at startup: start after the issuer (Kanidm behind
  # Caddy) when this host serves it.
  issuerUnits =
    lib.optional config.darkone.service.idm.enable "kanidm.service"
    ++ lib.optional config.services.caddy.enable "caddy.service";
in
{
  options = {
    darkone.service.outline.enable = lib.mkEnableOption "Enable local outline service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.outline = {
        persist.dirs = [ "/var/lib/outline" ];
        proxy.servicePort = srvPort;
      };

      # Kanidm OAuth2 client template
      darkone.service.idm.oauth2.outline = {
        displayName = "Outline Documentation";
        imageFile = ./../../assets/app-icons/outline.svg;
        redirectPaths = [ "/auth/oidc.callback" ];
        landingPath = "/";

        # Kanidm advertises S256 in its discovery document only when PKCE is
        # required: the sole switch Outline reads (cf. `OIDC_ISSUER_URL`).
        allowInsecureClientDisablePkce = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "outline";

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = dnfLib.mkInternalFirewall host zone [ srvPort ];

      #------------------------------------------------------------------------
      # outline Service
      #------------------------------------------------------------------------

      # Re-encrypted alias of the kanidm-owned OAuth2 secret, readable by the
      # outline user (sops `key` field unmaps the master secret name).
      sops.secrets."${secret}-service" = {
        mode = "0400";
        owner = "outline";
        key = secret;
      };

      services.outline = {
        enable = true;
        publicUrl = params.href;
        port = srvPort;
        forceHttps = false;
        storage.storageType = "local";
        oidcAuthentication = {

          # Required by the nixpkgs module, unset below in favour of discovery.
          inherit (oidc) authUrl tokenUrl userinfoUrl;
          inherit clientId;
          clientSecretFile = config.sops.secrets."${secret}-service".path;
          displayName = "idm";
        };
      };

      systemd.services.outline = {

        # Outline enables PKCE from discovery only, and manual endpoints win
        # over the issuer: drop the URIs the nixpkgs module always sets.
        # Workaround `outline-oidc-issuer` (config/workarounds.nix).
        environment = {
          OIDC_ISSUER_URL = oidc.issuerUrl;
          OIDC_AUTH_URI = lib.mkForce null;
          OIDC_TOKEN_URI = lib.mkForce null;
          OIDC_USERINFO_URI = lib.mkForce null;
        };
        wants = issuerUnits;
        after = issuerUnits;

        # A pg/redis restart in the same activation, or an IdM still down after
        # the gate below, makes outline exit: pace the retries, yet still latch
        # failed on a real crash-loop (10 starts/300s).
        startLimitIntervalSec = 300;
        startLimitBurst = 10;
        serviceConfig = {
          RestartSec = "5s";

          # Covers the wait loop below (default 90s would race it).
          TimeoutStartSec = "150s";

          # Readiness gate: a real 200 on the discovery document. Caddy answers
          # 502 while Kanidm is down, and its bot filter 403s a `curl` User-Agent.
          # Best-effort: on timeout, start anyway and rely on Restart.
          ExecStartPre = lib.mkBefore [
            (pkgs.writeShellScript "outline-wait-oidc" ''
              url="${oidc.openidConfigUrl}"
              for _ in $(${pkgs.coreutils}/bin/seq 1 15); do
                code=$(${pkgs.curl}/bin/curl -sS -A dnf-wait-oidc -o /dev/null -w '%{http_code}' --max-time 4 "$url" || true)
                [ "$code" = "200" ] && exit 0
                ${pkgs.coreutils}/bin/sleep 3
              done
              echo "outline: OIDC issuer unreachable after ~100s, starting anyway" >&2
              exit 0
            '')
          ];
        };
      };
    })
  ];
}
