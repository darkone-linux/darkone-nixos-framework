# Nextcloud full-configured service.

{
  lib,
  config,
  pkgs,
  host,
  network,
  ...
}:
let
  cfg = config.darkone.service.nextcloud;
  port = 8089;

  # TODO: factoriser dans lib avec httpd
  mkDomain =
    defaultDomain:
    if lib.attrsets.hasAttrByPath [ "services" "nextcloud" "domain" ] host then
      host.services.nextcloud.domain
    else
      defaultDomain;
in
{
  options = {
    darkone.service.nextcloud.enable = lib.mkEnableOption "Enable local nextcloud service";
    darkone.service.nextcloud.domainName = lib.mkOption {
      type = lib.types.str;
      default = "nextcloud";
      description = "Domain name for nextcloud, registered in network configuration";
    };
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
        domainName = mkDomain cfg.domainName;
        displayName = "Nextcloud";
        description = "Cloud personnel local";
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
        virtualHosts."${mkDomain cfg.domainName}" = {
          listen = [
            {
              addr = "127.0.0.1";
              inherit port;
            }
          ];
        };
      };

      # Nextcloud main service
      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud32;
        hostName = mkDomain cfg.domainName;
        maxUploadSize = "16G";

        # TODO: true
        https = false;

        # Configuration de base
        config = {
          adminuser = cfg.adminUser;
          adminpassFile = "/etc/nextcloud-admin-pass";
          dbtype = "pgsql";
          trustedProxies = [
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
            (mkDomain cfg.domainName)
            "localhost"
          ];
          default_phone_region = lib.toUpper (builtins.substring 0 2 network.locale);
        };
      };

      # Assurer que PostgreSQL et Redis sont activés
      services.postgresql.enable = lib.mkDefault true;
      services.redis.servers.nextcloud.enable = lib.mkDefault true;
    })
  ];
}
