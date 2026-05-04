# A full-configured LaSuite Docs module. (wip)

{
  lib,
  dnfLib,
  config,
  pkgs,
  network,
  zone,
  host,
  ...
}:
let
  cfg = config.darkone.service.docs;
  srvPort = 4445;
  srvInternalIp = "127.0.0.1";
  defaultParams = {
    title = "LaSuite Docs";
    description = "My Documents";
    icon = "docs-collaboration";
    ip = "127.0.0.1";
  };
  params = dnfLib.extractServiceParams host network "docs" defaultParams;
  usesLocalMinio = cfg.s3Host == "127.0.0.1" || cfg.s3Host == "localhost";
  s3Url = "http://${cfg.s3Host}:${toString cfg.s3Port}/${cfg.s3Bucket}";
in
{
  options = {
    darkone.service.docs.enable = lib.mkEnableOption "Enable local docs service";
    darkone.service.docs.s3Host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "S3 backend hostname";
    };
    darkone.service.docs.s3Port = lib.mkOption {
      type = lib.types.port;
      default = 9000;
      description = "S3 backend port";
    };
    darkone.service.docs.s3Bucket = lib.mkOption {
      type = lib.types.str;
      default = "docs";
      description = "S3 bucket name for document storage";
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
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.docs.enable = true;
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ srvPort ];
      };

      #------------------------------------------------------------------------
      # Secrets
      #------------------------------------------------------------------------

      # We need an explicit lasuite-docs user for sops
      users.users.lasuite-docs = {
        isSystemUser = true;
        group = "lasuite-docs";
      };
      users.groups.lasuite-docs = { };

      # OIDC Secret
      sops.secrets.oidc-secret-lasuite-docs = { };
      sops.templates.docs-env = {
        content = ''
          OIDC_RP_CLIENT_SECRET=${config.sops.placeholder.oidc-secret-lasuite-docs}
        '';
        mode = "0400";
        owner = "lasuite-docs";
        restartUnits = [ "lasuite-docs.service" ];
      };

      #------------------------------------------------------------------------
      # docs Services
      #------------------------------------------------------------------------

      # Nginx LaSuite Docs virtualhost
      # Caddy reverse proxy -> LaSuite Docs Nginx virtualhost -> LaSuite Docs service
      services.nginx = {
        #enableGixy = false;

        # Redirige TOUS les virtualhosts (y compris celui de lasuite-docs)
        # vers localhost:4445 au lieu de 0.0.0.0:80
        defaultListen = [
          {
            addr = "127.0.0.1";
            port = 4445;
            ssl = false;
          }
        ];

        # Propage les headers upstream vers l'app
        recommendedProxySettings = true;
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
          DJANGO_ALLOWED_HOSTS = srvInternalIp;
          OIDC_OP_AUTHORIZATION_ENDPOINT = "https://idm.${zone.domain}/ui/oauth2";
          OIDC_OP_TOKEN_ENDPOINT = "https://idm.${zone.domain}/oauth2/token";
          OIDC_RP_CLIENT_ID = "lasuite-docs";
        };
        environmentFile = config.sops.templates.docs-env.path;
      };
    })
  ];
}
