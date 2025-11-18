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
with lib;
let
  cfg = config.darkone.host.minimal;
in
{
  options = {
    darkone.host.minimal.enable = mkEnableOption "Minimal host configuration";
    darkone.host.minimal.secure = mkEnableOption "Prefer more secure options (disable mutable users...)";
    darkone.host.minimal.enableHomepage = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "homepage" ] host;
      description = "Enable the auto-configured homepage service";
    };
    darkone.host.minimal.enableForgejo = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "forgejo" ] host;
      description = "Enable pre-configured forgejo git forge service";
    };
    darkone.host.minimal.enableImmich = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "immich" ] host;
      description = "Enable pre-configured immich service";
    };
    darkone.host.minimal.enableNextcloud = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "nextcloud" ] host;
      description = "Enable pre-configured nextcloud service";
    };
    darkone.host.minimal.enableNetdata = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "netdata" ] host;
      description = "Enable pre-configured Netdata service";
    };
    darkone.host.minimal.enableMonitoring = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "monitoring" ] host;
      description = "Enable pre-configured monitoring service (prometheus, grafana)";
    };
    darkone.host.minimal.enableVaultwarden = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "vaultwarden" ] host;
      description = "Enable pre-configured Vaultwarden service";
    };
    darkone.host.minimal.enableSyncthing = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "syncthing" ] host;
      description = "Enable a syncthing server";
    };
    darkone.host.minimal.enableMattermost = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "mattermost" ] host;
      description = "Enable a mattermost server";
    };
    darkone.host.minimal.enableMatrix = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "matrix" ] host;
      description = "Enable a matrix server";
    };
    darkone.host.minimal.enableNfsHomeShares = mkOption {
      type = types.bool;
      default = attrsets.hasAttrByPath [ "services" "nfs" ] host;
      description = "Enable a DNF nfs home shares";
    };
  };

  config = mkIf cfg.enable {

    # Darkone main modules
    darkone.system = {
      hardware.enable = true; # firmwares
      core.enableFirewall = mkDefault true;
      i18n.enable = mkDefault true;
    };

    # Minimum console features
    darkone.console = {
      zsh.enable = mkDefault true;
      zsh.enableForRoot = mkDefault true;
    };

    # No password for sudoers
    security.sudo.wheelNeedsPassword = mkDefault false;

    # Can manage users with useradd, usermod...
    # Note: sops module force mutable users.
    users.mutableUsers = mkDefault (!cfg.secure);

    # Enabled services
    darkone.service = {
      forgejo.enable = cfg.enableForgejo;
      homepage.enable = cfg.enableHomepage;
      immich.enable = cfg.enableImmich;
      matrix.enable = cfg.enableMatrix;
      mattermost.enable = cfg.enableMattermost;
      monitoring.enable = cfg.enableMonitoring;
      netdata.enable = cfg.enableNetdata;
      nextcloud.enable = cfg.enableNextcloud;
      syncthing.enable = cfg.enableSyncthing;
      vaultwarden.enable = cfg.enableVaultwarden;
    };
  };
}
