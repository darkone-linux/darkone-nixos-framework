# Nextcloud full-configured service.

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
    darkone.service.nextcloud.adminPassword = lib.mkOption {
      type = lib.types.str;
      default = "changeme";
      description = "Admin password for Nextcloud (change this!)";
    };
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.nextcloud = {
        inherit defaultParams;
        persist = {
          dirs = [ "/var/lib/nextcloud/data" ];
          dbDirs = [ "/var/lib/postgresql" ];
          varDirs = [
            "/var/lib/nextcloud/store-apps"
            "/var/lib/redis-nextcloud"
          ];
        };
        proxy.servicePort = port;
        proxy.extraConfig = ''
          header {
            X-Frame-Options "sameorigin"
            X-Content-Type-Options "nosniff"
            X-Robots-Tag "noindex,nofollow"
            X-Permitted-Cross-Domain-Policies "none"
            Referrer-Policy "no-referrer-when-downgrade"
            Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
          }
          request_body {
            max_size 200MB
          }
          encode gzip
        '';
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.nextcloud.enable = true;
      };

      # Initial admin password
      environment.etc."nextcloud-admin-pass".text = "changeme";

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

      # Nextcloud main service
      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud32;
        hostName = params.fqdn;
        maxUploadSize = "16G";
        https = false;

        # TODO: https://search.nixos.org/options?channel=unstable&show=services.nextcloud.secrets
        #secrets = {};

        # Configuration de base
        config = {
          adminuser = cfg.adminUser;
          adminpassFile = "/etc/nextcloud-admin-pass";
          dbtype = "pgsql";
        };

        # Base de données PostgreSQL
        database.createLocally = true;

        # Configuration PHP et cache
        phpOptions = {
          "opcache.interned_strings_buffer" = "16";
          "opcache.max_accelerated_files" = "10000";
          "opcache.memory_consumption" = "128";
          "opcache.revalidate_freq" = "1";
          "opcache.fast_shutdown" = "1";
        };

        # Cache Redis
        configureRedis = true;

        # Déverrouillage du app store
        #appstoreEnable = true;

        # Applications par défaut
        extraApps = with config.services.nextcloud.package.packages.apps; {

          # List of apps we want to install and are already packaged in
          # https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/nextcloud/packages/32.json
          inherit
            calendar
            contacts
            cospend
            deck
            groupfolders
            memories
            music
            notes
            richdocuments
            spreed
            ;
        };

        # Apps config
        autoUpdateApps.enable = true;

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
          mail_domain = "admin@${network.domain}";
        };
      };

      # Assurer que PostgreSQL et Redis sont activés
      # TODO: activer services.postgresqlBackup
      services.postgresql.enable = lib.mkDefault true;
      services.redis.servers.nextcloud.enable = lib.mkDefault true;
    })
  ];
}
