# Student profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home = {
    education.enableStudent = lib.mkDefault graphic;
    office = {
      enable = lib.mkDefault graphic;
      enableTools = lib.mkDefault graphic;
      enableEmail = lib.mkDefault false;
      enableOffice = lib.mkDefault graphic;
      enableProductivity = lib.mkDefault graphic;
    };
    music = {
      enable = lib.mkDefault true;
      enableCli = lib.mkDefault true;
      enableFun = lib.mkDefault graphic;
      enableTools = lib.mkDefault graphic;
      enableScore = lib.mkDefault graphic;
      enableCreator = lib.mkDefault graphic;
    };
    imagery = {
      enable = lib.mkDefault graphic;
      enablePro = lib.mkDefault graphic;
      enableCAD = lib.mkDefault graphic;
      enableCli = lib.mkDefault graphic;
    };
    video = {
      enable = lib.mkDefault graphic;
      enableTools = lib.mkDefault graphic;
      enableEditing = lib.mkDefault graphic;
    };
  };
}
