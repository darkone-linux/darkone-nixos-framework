# Teenager profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home = {
    office = {
      enable = lib.mkDefault graphic;
      enableTools = lib.mkDefault graphic;
      enableOffice = lib.mkDefault graphic;
      enableProductivity = lib.mkDefault graphic;
      enableCommunication = lib.mkDefault graphic;
    };
    games = {
      enableTeenager = lib.mkDefault graphic;
      enableCli = true;
    };
    education.enableStudent = lib.mkDefault graphic;
    music = {
      enable = lib.mkDefault true;
      enableCli = lib.mkDefault true;
      enableFun = lib.mkDefault graphic;
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
    audio = {
      enable = lib.mkDefault true;
      enableTools = lib.mkDefault graphic;
    };
  };
}
