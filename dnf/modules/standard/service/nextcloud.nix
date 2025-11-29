# Nextcloud full-configured service.

{
  lib,
  dnfLib,
  config,
  pkgs,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.nextcloud;
  port = 8089;

  # TODO: factoriser dans lib avec httpd
  params = dnfLib.extractServiceParams host "nextcloud" { description = "Local personal cloud"; };
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
        inherit params;
        persist = {
          dirs = [ "/var/lib/nextcloud/data" ];
          dbDirs = [ "/var/lib/postgresql" ];
          varDirs = [
            "/var/lib/nextcloud/store-apps"
            "/var/lib/redis-nextcloud"
          ];
        };
        proxy.servicePort = port;
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

      # Nextcloud main service
      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud32;
        hostName = params.fqdn;
        maxUploadSize = "16G";

        # TODO: true
        https = false;

        # Configuration de base
        config = {
          adminuser = cfg.adminUser;
          adminpassFile = "/etc/nextcloud-admin-pass";
          dbtype = "pgsql";
          trustedProxies = [
            "10.64.0.0/10"
            "10.0.0.0/8"
            "127.0.0.1"
            "::1"
          ];
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
            spreed
            ;
        };

        # Apps config
        autoUpdateApps.enable = true;

        # Paramètres supplémentaires
        settings = {
          overwriteprotocol = "http";
          trusted_domains = [
            "localhost"
            params.domain
            params.fqdn
          ];
          default_phone_region = lib.toUpper (builtins.substring 3 2 zone.locale);
        };
      };

      # Assurer que PostgreSQL et Redis sont activés
      services.postgresql.enable = lib.mkDefault true;
      services.redis.servers.nextcloud.enable = lib.mkDefault true;
    })
  ];
}
