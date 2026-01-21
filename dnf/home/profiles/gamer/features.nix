# Teenager profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home = {
    office = {
      enable = lib.mkDefault graphic;
      enableCommunication = lib.mkDefault graphic;
    };
    games = {
      enableTeenager = lib.mkDefault graphic;
      enableChild = lib.mkDefault graphic;
      enableStk = lib.mkDefault graphic;
      enableCli = true;
    };
    education.enableStudent = lib.mkDefault graphic;
    imagery.enable = lib.mkDefault graphic;
    video.enable = lib.mkDefault graphic;
    audio = {
      enable = lib.mkDefault true;
      enableTools = lib.mkDefault graphic;
    };
  };
}
