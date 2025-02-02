# Graphic environment with office softwares

{ lib, config, ... }:
let
  cfg = config.darkone.theme.office;
in
{
  options = {
    darkone.theme.office.enable = lib.mkEnableOption "Graphic environment with office softwares";
  };

  config = lib.mkIf cfg.enable {

    # Common packages features
    darkone.console.packages.enable = lib.mkDefault true;
    darkone.graphic.office.enable = lib.mkDefault true;
  };
}
