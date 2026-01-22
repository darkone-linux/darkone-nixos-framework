# Normal user profile features

{ lib, osConfig, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home = {
    office = {
      enable = lib.mkDefault graphic;
      enableCommunication = lib.mkDefault graphic;
      enableOffice = lib.mkDefault graphic;
      enableFirefox = lib.mkDefault graphic;
    };
    imagery.enable = lib.mkDefault graphic;
    music.enable = lib.mkDefault graphic;
    video.enable = lib.mkDefault graphic;
  };
}
