# Baby profile programs

{ lib, osConfig, ... }:
{
  darkone.home.games.enableBaby = lib.mkDefault osConfig.darkone.graphic.gnome.enable;
}
