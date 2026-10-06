# A full-configured LaSuite Docs module.

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  pkgs,
  network,
  zone,
  host,
  hosts,
  ...
}:
let
  cfg = config.darkone.service.docs;
  srvPort = dnfConfig.network.ports.docs;
  defaultParams = {
    title = "LaSuite Docs";
    description = "My Documents";
    icon = "docs-collaboration";
    ip = "127.0.0.1";
  };
  params = dnfLib.extractServiceParams host network "docs" defaultParams;

  inherit
    (dnfLib.mkOidcContext {
      name = "docs";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;
  usesLocalGarage = cfg.s3Host == "127.0.0.1" || cfg.s3Host == "localhost";
  s3Url = "http://${cfg.s3Host}:${toString cfg.s3Port}/${cfg.s3Bucket}";
in
{
  options = {
    darkone.service.docs = {
      enable = lib.mkEnableOption "Enable local docs service";
      s3Host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "S3 backend hostname";
      };
      s3Port = lib.mkOption {
        type = lib.types.port;
        default = dnfConfig.network.ports.garage;
        description = "S3 backend port";
      };
      s3Bucket = lib.mkOption {
        type = lib.types.str;
        default = "docs";
        description = "S3 bucket name for document storage";
      };
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.docs = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/lasuite-docs" ];
        proxy.servicePort = srvPort;
      };

      # Kanidm OAuth2 client template
      # -> https://github.com/numerique-gouv/docs/blob/main/docs/env.md
      darkone.service.idm.oauth2.docs = {
        displayName = "LaSuite Docs";
        imageFile = ./../../assets/app-icons/docs-collaboration.svg;

        # mozilla-django-oidc callback, mounted under the LaSuite Docs
        # API prefix by `impress` / `core` URL conf. Kanidm enforces an
        # exact match against this list.
        redirectPaths = [ "/api/v1.0/callback/" ];
        landingPath = "/";
        preferShortUsername = false;

        # PKCE enforced: impress exposes the `OIDC_USE_PKCE` toggle (set in the
        # service settings below) and django-lasuite preserves mozilla-django-oidc's
        # PKCE flow (its OIDCAuthenticationRequestView calls super().get()).
        allowInsecureClientDisablePkce = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "docs";

      #------------------------------------------------------------------------
      # Secrets
      #------------------------------------------------------------------------

      # OIDC client secret + local S3 credentials in one root-owned template:
      # systemd reads `EnvironmentFile=` before dropping to the dynamic user.
      # Remote S3 backends: credentials come from an override in `usr/`.
      sops.secrets = {
        ${secret} = { };
      }
      // lib.optionalAttrs usesLocalGarage {
        garage-docs-key-id = { };
        garage-docs-key-secret = { };
      };
      sops.templates.docs-env = {
        content = ''
          OIDC_RP_CLIENT_SECRET=${config.sops.placeholder.${secret}}
        ''
        + lib.optionalString usesLocalGarage ''
          AWS_S3_ACCESS_KEY_ID=${config.sops.placeholder.garage-docs-key-id}
          AWS_S3_SECRET_ACCESS_KEY=${config.sops.placeholder.garage-docs-key-secret}
        '';
        mode = "0400";
        restartUnits = [
          "lasuite-docs.service"
          "lasuite-docs-celery.service"
        ];
      };

      #------------------------------------------------------------------------
      # docs Services
      #------------------------------------------------------------------------

      # Caddy -> LaSuite Docs nginx vhost -> LaSuite Docs. Upstream declares the
      # vhost without `listen`, so nginx would bind 0.0.0.0:80 against Caddy:
      # this vhost's `listen` only is overridden, not the global `defaultListen`.
      services.nginx = {
        recommendedProxySettings = true;

        # Compute the "real" scheme seen by the outermost proxy (Caddy).
        # When Caddy is in front it sets `X-Forwarded-Proto: https`; when
        # the vhost is reached directly (debug, healthcheck) the header
        # is empty and we fall back to nginx's own $scheme.
        commonHttpConfig = ''
          map $http_x_forwarded_proto $lasuite_docs_proto {
            default $http_x_forwarded_proto;
            ""      $scheme;
          }
        '';

        virtualHosts.${params.fqdn} = {
          listen = [
            {
              addr = params.ip;
              port = srvPort;
              ssl = false;
            }
          ];

          # Django-facing locations drop the module's `recommendedProxySettings`
          # and restate every proxy header: nginx does not deduplicate
          # `proxy_set_header`, and two `X-Forwarded-Proto` loop Django on a
          # 301 to HTTPS (`ERR_TOO_MANY_REDIRECTS`).
          locations =
            let
              proxyHeaders = ''
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $lasuite_docs_proto;
                proxy_set_header X-Forwarded-Host $host;
                proxy_set_header X-Forwarded-Server $host;
              '';
              overrideHeaders = {
                recommendedProxySettings = lib.mkForce false;
                extraConfig = proxyHeaders;
              };
            in
            {
              "/api" = overrideHeaders;
              "/admin" = overrideHeaders;
              "/collaboration/api/" = overrideHeaders;
              "/collaboration/ws/" = overrideHeaders;
              "/media-auth" = overrideHeaders;
            };
        };
      };

      # Require local Garage when using localhost S3 backend
      darkone.service.garage.enable = lib.mkIf usesLocalGarage true;

      # Provision the Garage access key and bucket for docs.
      # Runs after `garage-init.service` (layout assigned) so bucket and
      # key operations always have a ready cluster. Idempotent: safe to
      # re-run on every boot or after config changes.
      systemd.services.garage-docs-init = lib.mkIf usesLocalGarage {
        description = "Provision Garage bucket and key for LaSuite Docs";
        after = [ "garage-init.service" ];
        requires = [ "garage-init.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;

          # Provides GARAGE_RPC_SECRET for the CLI to reach the daemon.
          EnvironmentFile = config.sops.templates.garage-env.path;
        };
        script = ''
          set -eu

          key_id=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.garage-docs-key-id.path})
          key_secret=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.garage-docs-key-secret.path})

          # Import the access key under the stable name "docs" if absent.
          if ! ${pkgs.garage}/bin/garage key info docs >/dev/null 2>&1; then
            ${pkgs.garage}/bin/garage key import --yes -n docs "$key_id" "$key_secret"
          fi

          # Create the bucket if absent (silence the "already exists" error).
          if ! ${pkgs.garage}/bin/garage bucket info ${cfg.s3Bucket} >/dev/null 2>&1; then
            ${pkgs.garage}/bin/garage bucket create ${cfg.s3Bucket}
          fi

          # Re-applying the same grant is a no-op.
          ${pkgs.garage}/bin/garage bucket allow --read --write ${cfg.s3Bucket} --key docs
        '';
      };

      # Main service
      services.lasuite-docs = {
        enable = true;
        enableNginx = true;
        domain = params.fqdn;
        inherit s3Url;
        redis.createLocally = true;
        postgresql.createLocally = true;
        settings = {
          LANGUAGE_CODE = zone.lang;

          # OIDC (mozilla-django-oidc). Endpoints aligned on the Kanidm API;
          # secret + scope/algo signed with ES256.
          OIDC_OP_AUTHORIZATION_ENDPOINT = oidc.authUrl;
          OIDC_OP_TOKEN_ENDPOINT = oidc.tokenUrl;
          OIDC_OP_USER_ENDPOINT = oidc.userinfoUrl;
          OIDC_OP_JWKS_ENDPOINT = oidc.jwksUrl;
          OIDC_RP_CLIENT_ID = clientId;
          OIDC_RP_SIGN_ALGO = "ES256";
          OIDC_RP_SCOPES = "openid email profile";
          OIDC_CREATE_USER = "true";

          # Enable PKCE (S256 by default). Nix `true` -> Python `True`, parsed
          # by django-configurations BooleanValue. Kanidm enforces PKCE on this
          # client (allowInsecureClientDisablePkce = false in the template).
          OIDC_USE_PKCE = true;
          OIDC_REDIRECT_ALLOWED_HOSTS = params.fqdn;
          LOGIN_REDIRECT_URL = params.href;
          LOGIN_REDIRECT_URL_FAILURE = "${params.href}?login_failed=1";
          LOGOUT_REDIRECT_URL = params.href;

          # S3 credentials: ACCESS_KEY/SECRET are injected via
          # `sops.templates.docs-env` (see above). Endpoint and bucket are
          # static on the Nix side.
          AWS_S3_ENDPOINT_URL = "http://${cfg.s3Host}:${toString cfg.s3Port}";
          AWS_STORAGE_BUCKET_NAME = cfg.s3Bucket;

          # Must match Garage's `s3_api.s3_region`. For remote backends,
          # this default is overridable from `usr/`.
          AWS_S3_REGION_NAME =
            if usesLocalGarage then config.darkone.service.garage.s3Region else "us-east-1";
        };
        environmentFile = config.sops.templates.docs-env.path;
      };
    })
  ];
}
