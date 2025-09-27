# Features for childs and babies.

{ lib, config, ... }:
let
  cfg = config.darkone.theme.children;
in
{
  options = {
    darkone.theme.children.enable = lib.mkEnableOption "Children softwares";
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
