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
  darkone.home = {
    office = {
      enable = lib.mkDefault graphic;
      enableTools = lib.mkDefault true;
      enableLibreOffice = lib.mkDefault true;
      enableEmail = lib.mkDefault false;
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
      enableBeginner = lib.mkDefault graphic;
    };
    imagery = {
      enable = true;
      enablePro = true;
      enableCAD = true;
    };
    video = {
      enable = true;
      enableTools = true;
      enableEditing = true;
    };
  };

  home.packages = with pkgs; [ super-productivity ];
}
