# Child profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home = {
    games = {
      enableChild = lib.mkDefault graphic;
      enableCli = lib.mkDefault true;
    };
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
      enableOffice = lib.mkDefault graphic;
    };
    imagery = {
      enable = lib.mkDefault graphic;
      enableBeginner = lib.mkDefault graphic;
    };
    video.enable = lib.mkDefault graphic;
  };
}
