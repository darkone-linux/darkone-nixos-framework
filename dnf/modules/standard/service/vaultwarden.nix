# A full-configured vaultwarden server (wip).

{
  lib,
  config,
  pkgs,
  dnfLib,
  host,
  network,
  ...
}:
let
  cfg = config.darkone.service.vaultwarden;
  srv = config.services.vaultwarden.config;
  defaultParams = {
    icon = "vaultwarden-light";
  };
  params = dnfLib.extractServiceParams host network "vaultwarden" defaultParams;
in
{
  options = {
    darkone.service.vaultwarden.enable = lib.mkEnableOption "Enable local Vaultwarden service";
    darkone.service.vaultwarden.enableSmtp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SMTP to send emails (recommended)";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.vaultwarden = {
        inherit defaultParams;
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

      #--------------------------------------------------------------------------
      # Security
      #--------------------------------------------------------------------------

      # Données d'environnement critiques hébergée par sops
      # https://github.com/NixOS/nixpkgs/blob/a6531044f6d0bef691ea18d4d4ce44d0daa6e816/nixos/modules/services/security/vaultwarden/default.nix#L11
      sops.secrets."smtp/password" = { };
      sops.secrets.oidc-secret-vaultwarden = { };
      sops.templates.vaultwarden-env = {
        content = ''
          SMTP_PASSWORD=${config.sops.placeholder."smtp/password"}
          SSO_CLIENT_SECRET=${config.sops.placeholder.oidc-secret-vaultwarden}
        '';
        mode = "0400";
        owner = "vaultwarden";
      };

      #------------------------------------------------------------------------
      # Vaultwarden Service
      #------------------------------------------------------------------------

      # The CLI tool
      environment.systemPackages = [ pkgs.vaultwarden ];

      # The service
      services.vaultwarden = {
        enable = true;
        environmentFile = config.sops.templates.vaultwarden-env.path;
        config = {

          DOMAIN = params.href;
          SIGNUPS_ALLOWED = false; # TODO: SSO (change to true the first time)
          ROCKET_ADDRESS = params.ip;
          ROCKET_PORT = 8222;
          ROCKET_LOG = "critical";

          # Put SMTP_PASSWORD in sops environmentFile
          SMTP_HOST = network.smtp.server;
          SMTP_PORT = network.smtp.port;
          SMTP_SSL = network.smtp.tls;
          SMTP_USERNAME = network.smtp.username;
          SMTP_SECURITY = lib.mkIf network.smtp.tls "force_tls";
          SMTP_FROM = "no-reply@${network.domain}";
          SMTP_FROM_NAME = "Vaultwarden ${params.fqdn}";

          # TODO: fonctionnera avec https://github.com/Timshel/OIDCWarden
          # SSO
          SSO_ENABLED = true;
          SSO_ONLY = false;
          SSO_AUTHORITY = "https://idm.${network.domain}/oauth2/openid/vaultwarden";
          SSO_SCOPES = "openid email profile";
          SSO_PKCE = true;
          SSO_CLIENT_ID = "vaultwarden";
          SSO_SYNC_ON_REFRESH = true;
        };

        # TODO: local backup strategy
        #backupDir = "/persist/backup/vaultwarden";
      };
    })
  ];
}
