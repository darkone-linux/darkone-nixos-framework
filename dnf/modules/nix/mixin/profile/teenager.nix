# Features for teenagers.
#
# :::note[Host profile vs Home profile]
# This module enables features for all users of the system.
# Use HomeManager profiles to provide software tailored to each user (admin, advanced, student, child, teenager, etc.).
# :::

{ lib, config, ... }:
let
  cfg = config.darkone.profile.teenager;
in
{
  options = {
    darkone.profile.teenager.enable = lib.mkEnableOption "Teenager softwares";
  };

  config = lib.mkIf cfg.enable {

    # Additional features for teens
    darkone.graphic.education.enable = lib.mkDefault true;
    darkone.graphic.education.enableTeenager = lib.mkDefault true;
    darkone.graphic.games.enable = lib.mkDefault true;
  };
}
