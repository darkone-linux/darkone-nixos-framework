# A full-configured forgejo git forge.

{
  lib,
  dnfLib,
  config,
  network,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.forgejo;
  fjCfg = config.services.forgejo;
  srv = fjCfg.settings.server;
  params = dnfLib.extractServiceParams host network "forgejo" { };
in
{
  options = {
    darkone.service.forgejo.enable = lib.mkEnableOption "Enable local forgejo service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.forgejo = {
        persist.dirs = [
          "/var/lib/forgejo/custom"
          "/var/lib/forgejo/data"
          "/var/lib/forgejo/repositories"
        ];
        proxy.servicePort = srv.HTTP_PORT;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.forgejo.enable = true;
      };

      #------------------------------------------------------------------------
      # Forgejo Service
      #------------------------------------------------------------------------

      services.forgejo = {
        enable = true;
        package = pkgs.forgejo;
        database.type = "postgres";
        lfs.enable = true;
        settings = {
          server = {
            DOMAIN = host.ip;
            ROOT_URL = params.href; # URL before reverse proxy
            HTTP_PORT = 3000;
            LANDING_PAGE = "explore";
          };
          DEFAULT = {
            APP_NAME = params.title;
          };

          # You can temporarily allow registration to create an admin user.
          service.DISABLE_REGISTRATION = false;
          service.SHOW_REGISTRATION_BUTTON = false;
          service.ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          "service.explore".DISABLE_USERS_PAGE = true;
          "service.explore".DISABLE_ORGANIZATIONS_PAGE = true;
          "ui.meta".AUTHOR = "Darkone Linux";
          "ui.meta".DESCRIPTION = params.description;

          # Add support for actions, based on act: https://github.com/nektos/act
          actions = {
            ENABLED = false;
            DEFAULT_ACTIONS_URL = "github";
          };

          openid = {
            ENABLE_OPENID_SIGNIN = false;
            ENABLE_OPENID_SIGNUP = true;
          };

          oauth2_client = {
            USERNAME = "nickname";
            ENABLE_AUTO_REGISTRATION = true;
            REGISTER_EMAIL_CONFIRM = false;
            ACCOUNT_LINKING = "disabled"; # auto / login
            # OPENID_CONNECT_SCOPES = "openid email profile groups";
            # OPENID_CONNECT_AUTO_DISCOVER_URL = "https://dex.ag.poncon.fr/.well-known/openid-configuration";
            # OPENID_CONNECT_CLIENT_ID = "forgejo";
            # OPENID_CONNECT_CLIENT_SECRET = "test42";
            # OPENID_CONNECT_USERNAME = "preferred_username";
            # OPENID_CONNECT_EMAIL = "email";
            # GROUP_CLAIM_NAME = "groups";
          };

          # TODO: Sending emails is completely optional
          # You can send a test email from the web UI at:
          # Profile Picture > Site Administration > Configuration >  Mailer Configuration
          # mailer = {
          #   ENABLED = false;
          #   SMTP_ADDR = "mail.cheznoo.net";
          #   FROM = "noreply@${params.fqdn}";
          #   USER = "noreply@${params.fqdn}";
          # };
        };
        #mailerPasswordFile = config.age.secrets.forgejo-mailer-password.path;
      };
    })
  ];
}
