# Nextcloud full-configured service.
#
# :::caution[Required sops secret]
# When enabled, this module reads the Nextcloud admin password from the sops
# secret `nextcloud-admin-password`. Add the entry to `usr/secrets/` before
# rebuilding, otherwise sops-nix activation will fail.
# :::

{
  lib,
  config,
  pkgs,
  zone,
  network,
  host,
  dnfLib,
  ...
}:
let
  cfg = config.darkone.service.nextcloud;
  srv = config.services.nextcloud;
  port = 8089;
  defaultParams = {
    description = "Local personal cloud";
  };
  params = dnfLib.extractServiceParams host network "nextcloud" defaultParams;
in
{
  options = {
    darkone.service.nextcloud.enable = lib.mkEnableOption "Enable local nextcloud service";
    darkone.service.nextcloud.adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Admin username for Nextcloud";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.nextcloud = {
        inherit defaultParams;
        persist = {
          dirs = [ srv.home ];
          dbDirs = [ config.services.postgresql.dataDir ];
          varDirs = [ "/var/lib/redis-nextcloud" ];
        };
        proxy.servicePort = port;

        # X-Content-Type-Options: nosniff -> Interdit au navigateur d’essayer de deviner le type MIME d’une ressource.
        # Referrer-Policy: no-referrer-when-downgrade -> Ne pas envoyer le referer dans le cas HTTPS → HTTP
        # (X-Frame-Options / X-Robots-Tag / Strict-Transport-Security viennent du helper.)
        proxy.extraConfig = dnfLib.mkCaddySecurityHeaders {
          maxUploadSize = "200MB";
          extraHeaders = ''
            X-Content-Type-Options "nosniff"
            Referrer-Policy "no-referrer-when-downgrade"
          '';
        };
      };

      # Kanidm OAuth2 client template (consumer wiring is TODO — see user_oidc / sociallogin)
      darkone.service.idm.oauth2.nextcloud = {
        displayName = "Nextcloud";
        imageFile = ./../../assets/app-icons/nextcloud.svg;
        redirectPaths = [
          "/login"
          "/apps/sociallogin/custom_oauth2/IDM"
          "/apps/sociallogin/custom_oidc/IDM"
          "/ui/oauth2"
        ];
        landingPath = "/";
        allowInsecureClientDisablePkce = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "nextcloud";

      #------------------------------------------------------------------------
      # Nextcloud dependencies
      #------------------------------------------------------------------------

      # Initial admin password, provisioned from sops.
      # The corresponding entry must exist in usr/secrets/.
      sops.secrets."nextcloud-admin-password" = {
        mode = "0400";
        owner = "nextcloud";
      };

      # Internal nginx
      services.nginx = {
        virtualHosts."${params.fqdn}" = {
          listen = [
            {
              addr = params.ip;
              inherit port;
            }
          ];
        };
      };

      # Whiteboard server (TODO: automatiser)
      # nextcloud-occ config:app:set whiteboard collabBackendUrl --value="${params.href}"
      # nextcloud-occ config:app:set whiteboard jwt_secret_key --value="test123"
      services.nextcloud-whiteboard-server = {
        enable = true;
        settings.NEXTCLOUD_URL = params.href;
        secrets = [ "/etc/nextcloud-whiteboard-secret" ];
      };
      environment.etc."nextcloud-whiteboard-secret".text = ''
        JWT_SECRET_KEY=test123
      '';

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = dnfLib.mkInternalFirewall host zone [ port ];

      #------------------------------------------------------------------------
      # Nextcloud Service
      #------------------------------------------------------------------------

      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud33;
        hostName = params.fqdn;
        maxUploadSize = "16G";
        https = false;

        # TODO: https://search.nixos.org/options?channel=unstable&show=services.nextcloud.secrets
        #secrets = {};

        # Configuration de base
        config = {
          adminuser = cfg.adminUser;
          adminpassFile = config.sops.secrets."nextcloud-admin-password".path;
          dbtype = "pgsql";
        };

        # Base de données PostgreSQL
        database.createLocally = true;

        # Configuration PHP et cache
        phpOptions = {
          "opcache.interned_strings_buffer" = "64";
          "opcache.max_accelerated_files" = "10000";
          "opcache.memory_consumption" = "256";
          "opcache.revalidate_freq" = "1";
          "opcache.fast_shutdown" = "1";
        };

        # Cache Redis
        configureRedis = true;

        # Déverrouillage du app store
        appstoreEnable = false;

        # Applications par défaut
        extraApps = with config.services.nextcloud.package.packages.apps; {

          # List of apps we want to install and are already packaged in
          # https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/nextcloud/packages/32.json
          inherit
            calendar
            contacts
            cospend
            #deck
            groupfolders
            #memories
            music
            notes
            richdocuments
            spreed
            #user_oidc # Ne marche pas
            sociallogin
            ;
        };

        # Apps config
        autoUpdateApps.enable = true;

        # Client Push
        # TODO: service à part, accessible en HTTPS
        #notify_push.enable = true;

        # Paramètres supplémentaires
        settings = {
          overwriteprotocol = "https";
          trusted_domains = [
            "localhost"
            params.domain
            params.fqdn
          ];
          trusted_proxies = [
            "10.64.0.0/10"
            "10.0.0.0/8"
            "127.0.0.1"
            "::1"
          ];
          default_phone_region = lib.toUpper (builtins.substring 3 2 zone.locale);

          # SMTP params
          # Ne fonctionne que si l'adresse email de l'administrateur est renseignée dans son compte !
          mail_domain = network.domain;
          mail_smtpmode = "smtp";
          mail_sendmailmode = "smtp";
          mail_smtpport = network.smtp.port or 25;
          mail_smtpname = network.smtp.username or "";
          mail_smtphost = network.smtp.server or "";
          mail_smtpauth = true;
          mail_smtpsecure = lib.optionalString network.smtp.tls "ssl";
          mail_smtptimeout = 30;
          mail_from_address = "noreply";

          # user_oidc = {
          #   "httpclient.allowselfsigned" = true;
          #   "default_token_endpoint_auth_method" = "client_secret_post";
          #   "login_label" = "Se connecter avec l'IDM";
          # };
        };
      };

      # Assurer que PostgreSQL et Redis sont activés
      # TODO: activer services.postgresqlBackup
      services.postgresql.enable = lib.mkDefault true;
      services.redis.servers.nextcloud.enable = lib.mkDefault true;

      # Sauvegarde postgresql (par défaut toutes les bases)
      services.postgresqlBackup.enable = true;
    })
  ];
}
