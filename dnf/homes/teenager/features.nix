# Teenager profile features

{
  pkgs,
  lib,
  osConfig,
  ...
}:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  darkone.home.games.enableTeenager = lib.mkDefault graphic;
  darkone.home.education.enableStudent = lib.mkDefault graphic;
  darkone.home.music = {
    enable = lib.mkDefault true;
    enableCli = lib.mkDefault true;
    enableFun = lib.mkDefault graphic;
    enableScore = lib.mkDefault graphic;
    enableBeginner = lib.mkDefault graphic;
  };
  darkone.home.office = {
    enable = lib.mkDefault graphic;
    enableTools = lib.mkDefault false;
    enableLibreOffice = lib.mkDefault graphic;
    enableBrave = lib.mkDefault graphic;
    enableFirefox = lib.mkDefault false;
    enableChromium = lib.mkDefault false;
    enableEmail = lib.mkDefault false;
  };
  darkone.home.imagery = {
    enable = true;
    enablePro = true;
    enableCAD = true;
  };

  home.packages = with pkgs; [
    inkscape
    super-productivity
  ];
}
