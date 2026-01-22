# Baby profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home.games = {
    enable = lib.mkDefault graphic;
    enableBaby = lib.mkDefault graphic;
  };
  darkone.home.education = {
    enable = lib.mkDefault graphic;
    enableBaby = lib.mkDefault graphic;
  };
}
