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
    darkone.graphic.education.enable = lib.mkDefault true;
    darkone.graphic.education.enableBaby = lib.mkDefault true;
    darkone.graphic.education.enableGames = lib.mkDefault true;
  };
}
