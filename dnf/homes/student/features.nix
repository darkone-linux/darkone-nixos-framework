# Student profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home.education.enableStudent = lib.mkDefault graphic;
  darkone.home.imagery = {
    enable = true;
    enablePro = true;
    enableCAD = true;
  };
}
