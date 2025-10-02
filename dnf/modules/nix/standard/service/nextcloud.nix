# Nextcloud full-configured service.

{
  lib,
  config,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.nextcloud;
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

    # Virtualhost for nextcloud
    services.nginx = {
      enable = lib.mkForce true;
    };

    # Add nextcloud domain to /etc/hosts
    networking.hosts."${host.ip}" = lib.mkIf config.services.dnsmasq.enable [ "${cfg.domainName}" ];

    # Add nextcloud in Administration section of homepage
    darkone.service.homepage.appServices = [
      {
        "Nextcloud" = {
          description = "Cloud personnel local";
          href = "http://${cfg.domainName}";
          icon = "nextcloud";
        };
      }
    ];

    # Initial admin password
    environment.etc."nextcloud-admin-pass".text = "changeme";

    services.nextcloud = {
      enable = true;
      package = pkgs.nextcloud31;
      hostName = cfg.domainName;

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
          cfg.domainName
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
