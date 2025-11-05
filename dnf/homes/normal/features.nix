# Normal user profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home.office = {
    enable = lib.mkDefault graphic;
    enableTools = lib.mkDefault false;
    enableLibreOffice = lib.mkDefault graphic;
    enableBrave = lib.mkDefault false;
    enableFirefox = lib.mkDefault false;
    enableChromium = lib.mkDefault false;
    enableEmail = lib.mkDefault false;
  };
  darkone.home.imagery.enable = true;
}
