# Teenager profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home = {
    office = {
      enable = lib.mkDefault graphic;
      enableTools = lib.mkDefault false;
      enableEmail = lib.mkDefault false;
      enableOffice = lib.mkDefault false;
      enableProductivity = lib.mkDefault false;
      enableCommunication = lib.mkDefault graphic;
    };
    games = {
      enableTeenager = lib.mkDefault graphic;
      enableChild = lib.mkDefault graphic;
      enableStk = lib.mkDefault graphic;
      enableCli = true;
    };
    education.enableStudent = lib.mkDefault graphic;
    music.enable = lib.mkDefault false;
    imagery = {
      enable = lib.mkDefault graphic;
      enablePro = false;
      enableCAD = false;
    };
    video = {
      enable = lib.mkDefault graphic;
      enableTools = false;
      enableEditing = false;
    };
  };
}
