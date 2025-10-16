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
      description = "Domain name for nextcloud, registered in nextcloud, nginx & hosts";
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

  config = lib.mkIf cfg.enable {

    # httpd + dnsmasq + homepage registration
    darkone.system.service = {
      enable = true;
      service.nextcloud = {
        enable = true;
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
        nginx.manageVirtualHost = false;
      };
    };

    # Initial admin password
    environment.etc."nextcloud-admin-pass".text = "changeme";

    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud31;
      hostName = mkDomain cfg.domainName;
      maxUploadSize = "16G";

      # TODO: true
      https = false;

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
      appstoreEnable = true;

      # Applications par défaut
      extraApps = with config.services.nextcloud.package.packages.apps; {

        # List of apps we want to install and are already packaged in
        # https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/nextcloud/packages/nextcloud-apps.json
        inherit
          calendar
          contacts
          cospend
          deck
          files_mindmap
          groupfolders
          maps
          music
          notes
          tasks
          #cookbook
          #files_markdown
          #memories
          #unroundedcorners
          ;
        passwords = pkgs.fetchNextcloudApp {
          url = "https://git.mdns.eu/api/v4/projects/45/packages/generic/passwords/2025.10.0/passwords.tar.gz";
          sha256 = "sha256-3vTlJKOKiLVc9edPMRW+A/K2pXHYV+uY/in8ccYU6PE=";
          license = "gpl3";
        };
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
  };
}
