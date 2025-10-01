# Graphic environment with office softwares.
#
# :::note[Host profile vs Home profile]
# This module enables features for all users of the system.
# Use HomeManager profiles to provide software tailored to each user (admin, advanced, student, child, teenager, etc.).
# :::

{ lib, config, ... }:
let
  cfg = config.darkone.profile.office;
in
{
  options = {
    darkone.profile.office.enable = lib.mkEnableOption "Graphic environment with office softwares";
  };

  config = lib.mkIf cfg.enable {

    # Common packages features
    darkone.console.packages.enable = lib.mkDefault true;
    darkone.graphic.office.enable = lib.mkDefault true;
  };
}
