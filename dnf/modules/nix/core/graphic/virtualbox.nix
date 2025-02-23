{ lib, config, ... }:
let
  cfg = config.darkone.graphic.virtualbox;
  all-users = builtins.attrNames config.users.users;
  normal-users = builtins.filter (user: config.users.users.${user}.isNormalUser) all-users;
in
{
  options = {
    darkone.graphic.virtualbox.enable = lib.mkEnableOption "Pre-configured virtualbox installation";
    darkone.graphic.virtualbox.enableExtensionPack = lib.mkEnableOption "Enable extension pack (causes recompilations)";
  };

  config = lib.mkIf cfg.enable {

    # Virtualbox module
    nixpkgs.config.allowUnfree = lib.mkForce true;
    virtualisation.virtualbox.host.enable = lib.mkForce true;
    virtualisation.virtualbox.host.enableExtensionPack = cfg.enableExtensionPack;

    # Permissions
    users.extraGroups.vboxusers.members = normal-users;
  };
}
