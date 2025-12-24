# Advanced user home profile (admin, developer, etc.)

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home.advanced.enable = lib.mkDefault true;
  darkone.home.video.enable = lib.mkDefault graphic;
}
