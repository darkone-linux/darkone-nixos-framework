# A full-configured forgejo git forge.

{
  lib,
  dnfLib,
  config,
  network,
  host,
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
          service.DISABLE_REGISTRATION = true;
          "service.explore".DISABLE_USERS_PAGE = true;
          "ui.meta".AUTHOR = "Darkone Linux";
          "ui.meta".DESCRIPTION = params.description;

          # Add support for actions, based on act: https://github.com/nektos/act
          actions = {
            ENABLED = false;
            DEFAULT_ACTIONS_URL = "github";
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
