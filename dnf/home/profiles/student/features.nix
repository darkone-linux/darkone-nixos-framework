# Student profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home = {
    education.enableStudent = lib.mkDefault graphic;
    imagery = {
      enable = true;
      enablePro = true;
      enableCAD = true;
    };
    video = {
      enable = true;
      enableTools = true;
      enableEditing = true;
    };
  };
}
