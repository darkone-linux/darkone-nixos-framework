# A full-configured vaultwarden server (wip).

{
  lib,
  dnfLib,
  config,
  pkgs,
  host,
  ...
}:
let
  cfg = config.darkone.service.vaultwarden;
  srv = config.services.vaultwarden.config;
  params = dnfLib.extractServiceParams host "vaultwarden" { };
in
{
  options = {
    darkone.service.vaultwarden.enable = lib.mkEnableOption "Enable local Vaultwarden service";
  };

  # TODO: work in progress, activate TLS + FQDN
  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.vaultwarden = {
        inherit params;
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
          DOMAIN = params.href;
          SIGNUPS_ALLOWED = true; # TODO: false
          ROCKET_ADDRESS = params.ip;
          ROCKET_PORT = 8222;
          ROCKET_LOG = "critical";

          # TODO: Mail server
          #SMTP_HOST = "127.0.0.1";
          #SMTP_PORT = 25;
          #SMTP_SSL = false;
          #SMTP_FROM = "${params.domain}@${network.domain}";
          #SMTP_FROM_NAME = "${network.domain} Vaultwarden server";
        };

        # TODO: local backup strategy
        #backupDir = "/persist/backup/vaultwarden";
      };
    })
  ];
}
