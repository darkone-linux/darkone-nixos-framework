# A full-configured LaSuite Docs module.

{
  lib,
  dnfLib,
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
  srvPort = 4445;
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
        default = 3900;
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

        # impress v4.x ships mozilla-django-oidc 4.0.1 (which can do
        # PKCE) but does not set `OIDC_USE_PKCE = True` and does not
        # expose the toggle as a django-configurations env value, so we
        # cannot opt-in without patching. Disable PKCE enforcement on
        # this client until upstream wires it up.
        allowInsecureClientDisablePkce = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "docs";

      #------------------------------------------------------------------------
      # Secrets
      #------------------------------------------------------------------------

      # OIDC client secret + S3 credentials (local only) injected via the
      # same template to load a single EnvironmentFile on the systemd side.
      # The template is root-owned: systemd reads `EnvironmentFile=` before
      # privilege drop, so the dynamic user (DynamicUser=true upstream)
      # does not need direct access.
      # For remote S3 backends, the module does not attempt to inject
      # credentials (provide via override in `usr/`).
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

      # Nginx LaSuite Docs virtualhost
      # Caddy reverse proxy -> LaSuite Docs Nginx virtualhost -> LaSuite Docs service
      #
      # The upstream `services.lasuite-docs` module declares the vhost
      # `${cfg.domain}` without `listen`; without an override, nginx binds 0.0.0.0:80
      # and conflicts with Caddy. We explicitly override the `listen` of the
      # docs vhost only, without touching the global `defaultListen` (which would
      # remain at `0.0.0.0:80` for any other vhost — to be fixed per module if
      # another nginx service is added later on the same host).
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

          # Each Django/backend-facing location below disables the
          # upstream `recommendedProxySettings = true` (set by the
          # lasuite-docs module) and re-declares the full set of proxy
          # headers manually. The reason: nginx does not deduplicate
          # `proxy_set_header` by name — appending an override after
          # the recommended-headers include would send two
          # `X-Forwarded-Proto` headers and Django would pick the wrong
          # one, looping on a 301 to HTTPS (`ERR_TOO_MANY_REDIRECTS`).
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
