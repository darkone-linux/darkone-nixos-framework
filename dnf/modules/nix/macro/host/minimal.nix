# All host configuration is based on this minimal config.

{ lib, config, ... }:
let

  # without .minimal
  cfg = config.darkone.host;
in
{
  options = {
    darkone.host.minimal.enable = lib.mkEnableOption "Minimal host configuration";

    # Securefull configuration
    darkone.host.secure = lib.mkEnableOption "Prefer more secure options";
  };

  config = lib.mkIf cfg.minimal.enable {

    # Darkone main modules
    darkone.system = {
      hardware.enable = true; # firmwares
      core.enableFirewall = lib.mkDefault true;
      i18n.enable = lib.mkDefault true;
    };

    # Minimum console features
    darkone.console.packages.enable = lib.mkDefault true;
    darkone.console.zsh.enable = lib.mkDefault true;
    darkone.console.zsh.enableForRoot = lib.mkDefault true;

    # No password for sudoers
    security.sudo.wheelNeedsPassword = lib.mkDefault false;

    # Can manage users with useradd, usermod...
    users.mutableUsers = lib.mkDefault (!cfg.secure);
  };
}
