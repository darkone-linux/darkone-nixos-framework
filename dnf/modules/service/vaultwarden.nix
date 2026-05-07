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
      sops.secrets.vaultwarden-admin-token = { };
      sops.templates.vaultwarden-env = {
        content = ''
          SMTP_PASSWORD=${config.sops.placeholder."smtp/password"}
          #SSO_CLIENT_SECRET=${config.sops.placeholder.oidc-secret-vaultwarden}
          ADMIN_TOKEN=${config.sops.placeholder.vaultwarden-admin-token}
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

          # General -> https://github.com/dani-garcia/vaultwarden/blob/1.35.2/.env.template
          # DOMAIN is required for SSO
          DOMAIN = params.href;
          SIGNUPS_ALLOWED = false;
          INVITATIONS_ALLOWED = true;
          ADMIN_SESSION_LIFETIME = 30; # minutes -> for /admin
          ROCKET_ADDRESS = params.ip;
          ROCKET_PORT = 8222;
          ROCKET_LOG = "critical";
          SENDS_ALLOWED = true;
          EMERGENCY_ACCESS_ALLOWED = false;
          EMAIL_CHANGE_ALLOWED = false;
          #LOG_LEVEL = "info";

          # Impossible de valider des comptes avec des emails
          #SIGNUPS_DOMAINS_WHITELIST = network.domain;

          # Put SMTP_PASSWORD in sops environmentFile
          SMTP_HOST = network.smtp.server;
          SMTP_PORT = network.smtp.port;
          SMTP_SSL = network.smtp.tls;
          SMTP_USERNAME = network.smtp.username;
          SMTP_SECURITY = lib.mkIf network.smtp.tls "force_tls";
          SMTP_FROM = "no-reply@${network.domain}";
          SMTP_FROM_NAME = "Vaultwarden ${params.fqdn}";

          #----------------------------------------------------------------------------------------
          # SSO
          # /!\ Le SSO n'empêche pas le mot de passe principal d'être saisi. /!\
          # -> Ne sert finalement à rien sauf à compliquer les choses...
          #----------------------------------------------------------------------------------------

          # # Activate the SSO
          # SSO_ENABLED = false;

          # # Client secret -> SOPS + Env
          # SSO_CLIENT_ID = "vaultwarden";

          # # "Disable email+Master password authentication" -> faux, il faut mettre le MDP principal.
          # # -> Activer ceci oblige d'être connecté au SSO pour se connecter à vaultwarden.
          # SSO_ONLY = false;

          # # On SSO Signup if a user with a matching email already exists make the association (default true)
          # SSO_SIGNUPS_MATCH_EMAIL = true;

          # # Allow unknown email verification status (default false).
          # # Allowing this with SSO_SIGNUPS_MATCH_EMAIL open potential account takeover.
          # # -> Kanidm doit envoyer un "email_verified" pour que le SSO fonctionne.
          # #    Eviter d'activer en même temps que SSO_SIGNUPS_MATCH_EMAIL.
          # # -> Génère un problème quand
          # SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION = true;

          # # The OpenID Connect Discovery endpoint without /.well-known/openid-configuration
          # SSO_AUTHORITY = "https://idm.${network.domain}/oauth2/openid/vaultwarden";

          # # Optional, allow to override scopes if needed (default "email profile")
          # SSO_SCOPES = "email profile"; # `openid` is implicit

          # # Activate PKCE for the Auth Code flow (default true).
          # SSO_PKCE = true;

          # # Enable to use SSO only for authentication not session lifecycle
          # SSO_AUTH_ONLY_NOT_SESSION = true;

          # # Appels de cache vers le point de terminaison de découverte
          # SSO_CLIENT_CACHE_EXPIRATION = 60; # Seconds
        };

        # TODO: local backup strategy
        # backupDir = "/persist/backup/vaultwarden";
      };
    })
  ];
}
