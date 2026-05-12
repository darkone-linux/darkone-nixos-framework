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

  # Historical kanidm client name predates the service-name convention.
  clientId = dnfLib.oauth2ClientName {
    name = "docs";
    clientName = "lasuite-docs";
  } params;

  secret = "oidc-secret-${clientId}";
  idmUrl = dnfLib.idmHref network hosts;
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

      # Kanidm OAuth2 client template (historical name kept via clientName override).
      # -> https://github.com/numerique-gouv/docs/blob/main/docs/env.md
      darkone.service.idm.oauth2.docs = {
        clientName = "lasuite-docs";
        displayName = "LaSuite Docs";
        imageFile = ./../../assets/app-icons/docs-collaboration.svg;
        # mozilla-django-oidc callback, monté sous le prefix API de LaSuite Docs.
        # À ajuster si Kanidm rejette avec `redirect_uri mismatch` (path exact à
        # vérifier dans le backend `impress` / `core` URL conf).
        redirectPaths = [ "/api/v1.0/authenticate/" ];
        landingPath = "/";
        preferShortUsername = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.docs.enable = true;
      };

      #------------------------------------------------------------------------
      # Secrets
      #------------------------------------------------------------------------

      # OIDC client secret + credentials S3 (locaux uniquement) injectés via le
      # même template pour ne charger qu'un seul EnvironmentFile côté systemd.
      # Le template est root-owned : systemd lit `EnvironmentFile=` avant le
      # drop de privilèges, donc le user dynamique (DynamicUser=true côté
      # upstream) n'a pas besoin d'accès direct.
      # En cas de backend S3 distant, le module ne tente pas d'injecter de
      # creds (à fournir via une surcharge dans `usr/`).
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
      # Le module upstream `services.lasuite-docs` déclare le vhost
      # `${cfg.domain}` sans `listen` ; sans override, nginx bind 0.0.0.0:80 et
      # entre en conflit avec Caddy. On surcharge donc explicitement le `listen`
      # du seul vhost docs, sans toucher au `defaultListen` global (qui resterait
      # à `0.0.0.0:80` pour tout autre vhost — à régler module par module si un
      # autre service nginx est ajouté plus tard sur le même hôte).
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

          # OIDC (mozilla-django-oidc). Endpoints alignés sur l'API Kanidm ;
          # secret + scope/algo signés ES256 (cf. mealie.nix:101).
          OIDC_OP_AUTHORIZATION_ENDPOINT = "${idmUrl}/ui/oauth2";
          OIDC_OP_TOKEN_ENDPOINT = "${idmUrl}/oauth2/token";
          OIDC_OP_USER_ENDPOINT = "${idmUrl}/oauth2/openid/${clientId}/userinfo";
          OIDC_OP_JWKS_ENDPOINT = "${idmUrl}/oauth2/openid/${clientId}/public_key.jwk";
          OIDC_RP_CLIENT_ID = clientId;
          OIDC_RP_SIGN_ALGO = "ES256";
          OIDC_RP_SCOPES = "openid email profile";
          OIDC_CREATE_USER = "true";
          OIDC_REDIRECT_ALLOWED_HOSTS = params.fqdn;
          LOGIN_REDIRECT_URL = params.href;
          LOGIN_REDIRECT_URL_FAILURE = "${params.href}?login_failed=1";
          LOGOUT_REDIRECT_URL = params.href;

          # Credentials S3 : ACCESS_KEY/SECRET sont injectés via
          # `sops.templates.docs-env` (cf. plus haut). Endpoint et bucket sont
          # statiques côté Nix.
          AWS_S3_ENDPOINT_URL = "http://${cfg.s3Host}:${toString cfg.s3Port}";
          AWS_STORAGE_BUCKET_NAME = cfg.s3Bucket;
          AWS_S3_REGION_NAME = "us-east-1";
        };
        environmentFile = config.sops.templates.docs-env.path;
      };
    })
  ];
}
