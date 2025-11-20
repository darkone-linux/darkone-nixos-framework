# Child profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home = {
    games.enableChild = lib.mkDefault graphic;
    education.enableChild = lib.mkDefault graphic;
    music = {
      enable = lib.mkDefault true;
      enableCli = lib.mkDefault true;
      enableFun = lib.mkDefault graphic;
      enableEasy = lib.mkDefault graphic;
    };
    office = {
      enable = lib.mkDefault graphic;
      enableEssentials = lib.mkDefault graphic;
      enableProductivity = lib.mkDefault graphic;
      enableTools = lib.mkDefault false;
      enableOffice = lib.mkDefault graphic;
      enableBrave = lib.mkDefault false;
      enableFirefox = lib.mkDefault false;
      enableChromium = lib.mkDefault false;
      enableEmail = lib.mkDefault false;
    };
    imagery = {
      enable = true;
      enableBeginner = true;
    };
  };
}
