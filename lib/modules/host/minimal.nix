{ lib, config, ... }:
let
  cfg = config.darkone.host;
in
{
  options = {
    darkone.host.minimal.enable = lib.mkEnableOption "Minimal host configuration";

    # Securefull configuration
    darkone.host.secure = lib.mkEnableOption "Prefer more secure options";

    # Host is a darkone network host by default
    darkone.host.isNode = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = "Is local network node";
    };
  };

  config = lib.mkIf cfg.minimal.enable {

    # Darkone main modules
    darkone.system = {
      core.enable = lib.mkDefault true;
      core.enableFirewall = lib.mkDefault true;
      i18n.enable = lib.mkDefault true;
    };

    # Minimum console features
    darkone.console.packages.enable = lib.mkDefault true;

    # No password for sudoers
    security.sudo.wheelNeedsPassword = lib.mkDefault false;

    # Can manage users with useradd, usermod...
    users.mutableUsers = lib.mkDefault (!cfg.secure);

    # Is a local network managed node (true by default)
    darkone.user.isNode = lib.mkDefault true;
  };
}
