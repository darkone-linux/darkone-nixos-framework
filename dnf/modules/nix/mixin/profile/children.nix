# Features for childs and babies.
#
# :::note[Host profile vs Home profile]
# This module enables features for all users of the system.
# Use HomeManager profiles to provide software tailored to each user (admin, advanced, student, child, teenager, etc.).
# :::

{ lib, config, ... }:
let
  cfg = config.darkone.profile.children;
in
{
  options = {
    darkone.profile.children.enable = lib.mkEnableOption "Children softwares";
  };

  config = lib.mkIf cfg.enable {

    # Additional features for children
    darkone.graphic = {
      education = {
        enable = lib.mkDefault true;
        enableBaby = lib.mkDefault true;
      };
      games.enable = lib.mkDefault true;
    };
  };
}
