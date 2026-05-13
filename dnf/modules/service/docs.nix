# A full-configured LaSuite Docs module. (wip)

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
  usesLocalMinio = cfg.s3Host == "127.0.0.1" || cfg.s3Host == "localhost";
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
        default = 9000;
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
        # mozilla-django-oidc callback, mounted under the LaSuite Docs API prefix.
        # Adjust if Kanidm rejects with `redirect_uri mismatch` (exact path to
        # check in the `impress` / `core` backend URL conf).
        redirectPaths = [ "/api/v1.0/authenticate/" ];
        landingPath = "/";
        preferShortUsername = false;
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
      sops.secrets.${secret} = { };
      sops.templates.docs-env = {
        content = ''
          OIDC_RP_CLIENT_SECRET=${config.sops.placeholder.${secret}}
        ''
        + lib.optionalString usesLocalMinio ''
          AWS_S3_ACCESS_KEY_ID=${config.sops.placeholder.minio-root-user}
          AWS_S3_SECRET_ACCESS_KEY=${config.sops.placeholder.minio-root-password}
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
        virtualHosts.${params.fqdn}.listen = [
          {
            addr = params.ip;
            port = srvPort;
            ssl = false;
          }
        ];
      };

      # Require local MinIO when using localhost S3 backend
      darkone.service.minio.enable = lib.mkIf usesLocalMinio true;

      # Create the S3 bucket after MinIO starts (local only)
      systemd.services.minio.postStart = lib.mkIf usesLocalMinio ''
        ${pkgs.mc}/bin/mc alias set docs-local http://${cfg.s3Host}:${toString cfg.s3Port} \
          "$(cat ${config.sops.secrets.minio-root-user.path})" \
          "$(cat ${config.sops.secrets.minio-root-password.path})" && \
        ${pkgs.mc}/bin/mc mb --ignore-existing docs-local/${cfg.s3Bucket}
      '';

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
          AWS_S3_REGION_NAME = "us-east-1";
        };
        environmentFile = config.sops.templates.docs-env.path;
      };
    })
  ];
}
