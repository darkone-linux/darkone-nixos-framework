# Graphic environment with office softwares.

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
