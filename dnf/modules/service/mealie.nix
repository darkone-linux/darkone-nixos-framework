# Mealie Recipe Management

{
  lib,
  dnfLib,
  config,
  network,
  host,
  hosts,
  pkgs-stable,
  ...
}:
let
  cfg = config.darkone.service.mealie;
  srv = config.services.mealie;
  inherit (network) smtp;
  params = dnfLib.extractServiceParams host network "mealie" { };
  clientId = dnfLib.oauth2ClientName { name = "mealie"; } params;
  secret = "oidc-secret-${clientId}";
  idmUrl = dnfLib.idmHref network hosts;
in
{
  options = {
    darkone.service.mealie.enable = lib.mkEnableOption "Enable mealie service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.mealie = {
        persist.dirs = [ "/var/lib/mealie" ];
        proxy.servicePort = srv.port;
      };

      # Kanidm OAuth2 client template
      darkone.service.idm.oauth2.mealie = {
        displayName = "Mealie";
        imageFile = ./../../assets/app-icons/mealie.svg;
        redirectPaths = [
          "/login"
          "/login?direct=1"
        ];
        landingPath = "/";
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.mealie.enable = true;
      };

      sops.secrets."smtp/password" = { };
      sops.secrets.${secret} = { };
      sops.templates.mealie-credentials = {
        content = ''
          SMTP_PASSWORD=${config.sops.placeholder."smtp/password"}
          OIDC_CLIENT_SECRET=${config.sops.placeholder.${secret}}
        '';
        mode = "0400";
        owner = "mealie";
      };

      # TMP: mealie user do not exists...
      users.users.mealie = {
        isSystemUser = true;
        group = "mealie";
      };
      users.groups.mealie = { };

      #------------------------------------------------------------------------
      # Mealie Service
      #------------------------------------------------------------------------

      services.mealie = {
        enable = true;
        package = pkgs-stable.mealie;
        listenAddress = params.ip;
        credentialsFile = config.sops.templates.mealie-credentials.path;
        settings = {
          DB_ENGINE = "sqlite"; # Default

          SMTP_HOST = smtp.server;
          SMTP_PORT = smtp.port;
          SMTP_USER = smtp.username;
          SMTP_FROM_NAME = "Maelie ${network.domain}";
          SMTP_FROM_EMAIL = "noreply@${network.domain}";
          SMTP_AUTH_STRATEGY = if smtp.tls then "SSL" else "NONE";

          OIDC_AUTH_ENABLED = "true";
          OIDC_CLIENT_ID = clientId;
          OIDC_USER_GROUP = "users@${network.domain}";
          OIDC_ADMIN_GROUP = "admins@${network.domain}";
          OIDC_AUTO_REDIRECT = "true";
          OIDC_SIGNING_ALGORITHM = "ES256";
          OIDC_CONFIGURATION_URL = "${idmUrl}/oauth2/openid/${clientId}/.well-known/openid-configuration";
          OIDC_PROVIDER_NAME = "IDM";
        };
      };
    })
  ];
}
