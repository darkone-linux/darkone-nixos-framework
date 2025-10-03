# Nextcloud full-configured service.

{
  lib,
  config,
  pkgs,
  host,
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
    darkone.service.httpd = {
      enable = true;
      service.nextcloud = {
        enable = true;
        domainName = mkDomain cfg.domainName;
        displayName = "Nextcloud";
        description = "Cloud personnel local";
        nginx.manageVirtualHost = false;
      };
    };

    # Initial admin password
    environment.etc."nextcloud-admin-pass".text = "changeme";

    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud31;
      hostName = mkDomain cfg.domainName;

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

      # Applications par défaut
      extraApps = {
        inherit (config.services.nextcloud.package.packages.apps)
          contacts
          calendar
          tasks
          notes
          memories
          ;
      };

      # Paramètres supplémentaires
      settings = {
        overwriteprotocol = "http";
        trusted_domains = [
          (mkDomain cfg.domainName)
          "localhost"
        ];
        default_phone_region = "FR";
      };
    };

    # Assurer que PostgreSQL et Redis sont activés
    services.postgresql.enable = lib.mkDefault true;
    services.redis.servers.nextcloud.enable = lib.mkDefault true;
  };
}
