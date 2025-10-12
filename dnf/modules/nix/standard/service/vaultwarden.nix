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
  config = lib.mkIf cfg.enable {

    # httpd + dnsmasq + homepage registration
    darkone.service.httpd = {
      enable = true;
      service.vaultwarden = {
        enable = true;
        inherit (cfg) domainName;
        displayName = "Vaultwarden";
        description = "Vaultwarden local server";
        nginx.manageVirtualHost = false;
      };
    };

    # Specific reverse proxy for vaultwarden
    services.nginx = {
      enable = lib.mkForce true;
      virtualHosts.${cfg.domainName} = {

        # TODO: TLS
        #forceSSL = true;
        #enableACME = true;

        extraConfig = ''
          access_log /var/log/nginx/${cfg.domainName}.access.log;
          error_log /var/log/nginx/${cfg.domainName}.error.log;
        '';
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString srv.ROCKET_PORT}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
      };
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

      # TODO: for impermanence
      #backupDir = "/persist/backup/vaultwarden";
    };
  };
}
