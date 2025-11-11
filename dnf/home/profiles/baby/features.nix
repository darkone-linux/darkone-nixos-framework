# Baby profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home.games.enableBaby = lib.mkDefault graphic;
  darkone.home.education.enableBaby = lib.mkDefault graphic;
}
