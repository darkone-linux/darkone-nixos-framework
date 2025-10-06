# Every host configuration is based on this minimal config.
#
# :::caution[Services declaration]
# A number of services (immich, nextcloud, forgejo, etc.) can be declared in the configuration `usr/config.yaml`
# of each host, regardless of its type (server, laptop, desktop, etc.). **It is advisable to declare them in the
# yaml file so that the service is visible across the entire network!**
# :::

{
  lib,
  config,
  host,
  ...
}:
let
  cfg = config.darkone.host.minimal;
in
{
  options = {
    darkone.host.minimal.enable = lib.mkEnableOption "Minimal host configuration";
    darkone.host.minimal.secure = lib.mkEnableOption "Prefer more secure options (disable mutable users...)";
    darkone.host.minimal.enableHomepage = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "homepage" host.services;
      description = "Enable the auto-configured homepage service";
    };
    darkone.host.minimal.enableForgejo = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "forgejo" host.services;
      description = "Enable pre-configured forgejo git forge service";
    };
    darkone.host.minimal.enableImmich = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "immich" host.services;
      description = "Enable pre-configured immich service";
    };
    darkone.host.minimal.enableNextcloud = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "nextcloud" host.services;
      description = "Enable pre-configured nextcloud service";
    };
    darkone.host.minimal.enableOwncloud = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "owncloud" host.services;
      description = "Enable pre-configured owncloud service";
    };
    darkone.host.minimal.enableNetdata = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "netdata" host.services;
      description = "Enable pre-configured Netdata service";
    };
    darkone.host.minimal.enableMonitoring = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "monitoring" host.services;
      description = "Enable pre-configured monitoring service (prometheus, grafana)";
    };
  };

  config = lib.mkIf cfg.enable {

    # Darkone main modules
    darkone.system = {
      hardware.enable = true; # firmwares
      core.enableFirewall = lib.mkDefault true;
      i18n.enable = lib.mkDefault true;
    };

    # Minimum console features
    darkone.console = {
      packages.enable = lib.mkDefault true;
      zsh.enable = lib.mkDefault true;
      zsh.enableForRoot = lib.mkDefault true;
    };

    # No password for sudoers
    security.sudo.wheelNeedsPassword = lib.mkDefault false;

    # Can manage users with useradd, usermod...
    # Note: sops module force mutable users.
    users.mutableUsers = lib.mkDefault (!cfg.secure);

    # Enabled services
    darkone.service = {
      homepage.enable = cfg.enableHomepage;
      forgejo.enable = cfg.enableForgejo;
      immich.enable = cfg.enableImmich;
      nextcloud.enable = cfg.enableNextcloud;
      owncloud.enable = cfg.enableOwncloud;
      netdata.enable = cfg.enableNetdata;
      monitoring.enable = cfg.enableMonitoring;
    };
  };
}
