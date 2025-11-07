# A full-configured vaultwarden server (wip).

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.vaultwarden;
  srv = config.services.vaultwarden.config;
in
{
  options = {
    darkone.service.vaultwarden.enable = lib.mkEnableOption "Enable local Vaultwarden service";
    darkone.service.vaultwarden.domainName = lib.mkOption {
      type = lib.types.str;
      default = "vaultwarden";
      description = "Domain name for the Vaultwarden service";
    };
    darkone.service.vaultwarden.appName = lib.mkOption {
      type = lib.types.str;
      default = "Unofficial Bitwarden compatible server";
      description = "Default title for Vaultwarden server";
    };
  };

  # TODO: work in progress, activate TLS + FQDN
  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.vaultwarden = {
        inherit (cfg) domainName;
        displayName = "Vaultwarden";
        description = "Vaultwarden local server";
        persist = {
          files = [
            "rsa_key.pem"
            "rsa_key.pub.pem"
          ];
          dirs = [ "/var/lib/vaultwarden/attachments" ];
          dbDirs = [ "/var/lib/vaultwarden/db.sqlite3" ];
          varDirs = [ "/var/lib/vaultwarden/icon_cache" ];
        };
        proxy.servicePort = srv.ROCKET_PORT;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.vaultwarden.enable = true;
      };

      # The CLI tool
      environment.systemPackages = [ pkgs.vaultwarden ];

      # The service
      services.vaultwarden = {
        enable = true;
        config = {

          # TODO: FQDN + HTTPS
          DOMAIN = "http://vaultwarden";
          SIGNUPS_ALLOWED = true; # TODO: false
          ROCKET_ADDRESS = "127.0.0.1";
          ROCKET_PORT = 8222;
          ROCKET_LOG = "critical";

          # TODO: Mail server
          #SMTP_HOST = "127.0.0.1";
          #SMTP_PORT = 25;
          #SMTP_SSL = false;
          #SMTP_FROM = "vaultwarden@${cfg.domainName}.${network.domain}";
          #SMTP_FROM_NAME = "${network.domain} Vaultwarden server";
        };

        # TODO: local backup strategy
        #backupDir = "/persist/backup/vaultwarden";
      };
    })
  ];
}
