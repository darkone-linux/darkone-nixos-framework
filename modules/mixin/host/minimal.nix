# Every host configuration is based on this minimal config.
#
# :::caution[Services declaration]
# A number of services (immich, nextcloud, forgejo, etc.) can be declared in
# `usr/config.yaml` of each host, regardless of its type (server, laptop,
# desktop, etc.). **It is advisable to declare them in the yaml file so that
# the service is visible across the entire network!**
# :::

{
  lib,
  config,
  dnfConfig,
  dnfLib,
  host,
  ...
}:
let
  cfg = config.darkone.host.minimal;
  profileServicesArgs = {
    profileName = "minimal";
    inherit host;
    inherit (dnfConfig) modules;
  };
in
{
  options = {
    darkone.host.minimal.enable = lib.mkEnableOption "Minimal host configuration";
    darkone.host.minimal.secure = lib.mkEnableOption "Prefer more secure options (disable mutable users...)";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Darkone main modules
        darkone.system = {
          hardware.enable = true;
          core.enableFirewall = lib.mkDefault true;
          i18n.enable = lib.mkDefault true;
        };

        # Minimum console features
        darkone.console = {
          zsh.enable = lib.mkDefault true;
          zsh.enableForRoot = lib.mkDefault true;
        };

        # No password for sudoers
        security.sudo.wheelNeedsPassword = lib.mkDefault false;

        # Can manage users with useradd, usermod...
        # Note: sops module forces mutable users.
        users.mutableUsers = lib.mkDefault (!cfg.secure);
      }

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
