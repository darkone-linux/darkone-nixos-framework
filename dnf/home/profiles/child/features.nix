# Child profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home.games.enableChild = lib.mkDefault graphic;
  darkone.home.education.enableChild = lib.mkDefault graphic;
  darkone.home.music = {
    enable = lib.mkDefault true;
    enableCli = lib.mkDefault true;
    enableFun = lib.mkDefault graphic;
  };
  darkone.home.office = {
    enable = lib.mkDefault graphic;
    enableEssentials = lib.mkDefault false;
    enableObsidian = lib.mkDefault false;
    enableTools = lib.mkDefault false;
    enableLibreOffice = lib.mkDefault true;
    enableBrave = lib.mkDefault false;
    enableFirefox = lib.mkDefault false;
    enableChromium = lib.mkDefault false;
    enableEmail = lib.mkDefault false;
  };
  darkone.home.imagery = {
    enable = true;
    enableBeginner = true;
  };
}
