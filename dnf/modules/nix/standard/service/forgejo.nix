# A full-configured forgejo git forge.

{
  lib,
  config,
  host,
  network,
  ...
}:
let
  inherit network;
  cfg = config.darkone.service.forgejo;
  fjCfg = config.services.forgejo;
  srv = fjCfg.settings.server;
in
{
  options = {
    darkone.service.forgejo.enable = lib.mkEnableOption "Enable local forgejo service";
    darkone.service.forgejo.domainName = lib.mkOption {
      type = lib.types.str;
      default = "forgejo";
      description = "Domain name for the forge, registered in forgejo, nginx & hosts";
    };
    darkone.service.forgejo.appName = lib.mkOption {
      type = lib.types.str;
      default = "The local forge";
      description = "Default title for the local GIT forge";
    };
  };

  config = lib.mkIf cfg.enable {

    # Virtualhost for forgejo
    services.nginx = {
      enable = lib.mkForce true;
      virtualHosts.${cfg.domainName} = {
        extraConfig = ''
          client_max_body_size 512M;
        '';
        locations."/".proxyPass = "http://localhost:${toString srv.HTTP_PORT}";
      };
    };

    # Add forgejo domain to /etc/hosts
    networking.hosts."${host.ip}" = lib.mkIf config.services.dnsmasq.enable [ "${cfg.domainName}" ];

    # Add forgejo in Administration section of homepage
    darkone.service.homepage.appServices = [
      {
        "Forgejo" = {
          description = "Forge GIT locale";
          href = "http://${cfg.domainName}";
          icon = "sh-forgejo";
        };
      }
    ];

    services.forgejo = {
      enable = true;
      database.type = "postgres";
      lfs.enable = true;
      settings = {
        server = {
          DOMAIN = "localhost";

          # You need to specify this to remove the port from URLs in the web UI.
          ROOT_URL = "http://${cfg.domainName}/";
          HTTP_PORT = 3000;
          LANDING_PAGE = "explore";
        };
        DEFAULT = {
          APP_NAME = cfg.appName;
        };

        # You can temporarily allow registration to create an admin user.
        service.DISABLE_REGISTRATION = true;
        "service.explore".DISABLE_USERS_PAGE = true;
        "ui.meta".AUTHOR = "Darkone Linux";
        "ui.meta".DESCRIPTION = "${network.domain} git forge";

        # Add support for actions, based on act: https://github.com/nektos/act
        actions = {
          ENABLED = true;
          DEFAULT_ACTIONS_URL = "github";
        };

        # TODO: Sending emails is completely optional
        # You can send a test email from the web UI at:
        # Profile Picture > Site Administration > Configuration >  Mailer Configuration
        # mailer = {
        #   ENABLED = false;
        #   SMTP_ADDR = "mail.cheznoo.net";
        #   FROM = "noreply@${srv.DOMAIN}.${network.domain}";
        #   USER = "noreply@${srv.DOMAIN}.${network.domain}";
        # };
      };
      #mailerPasswordFile = config.age.secrets.forgejo-mailer-password.path;
    };
  };
}
