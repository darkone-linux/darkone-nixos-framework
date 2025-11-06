# Gnome tweaks for home manager.

{ lib, config, ... }:

let
  cfg = config.darkone.home.gnome;
in
{
  options = {
    darkone.home.gnome.hideTechnicalIcons = lib.mkEnableOption "Hide some icons for beginners / children / babies";
  };

  config = lib.mkIf cfg.hideTechnicalIcons {
    xdg.desktopEntries = lib.mkIf cfg.hideTechnicalIcons {
      "xterm" = {
        name = "XTerm";
        exec = "xterm";
        type = "Application";
        noDisplay = true;
      };
      "org.gnome.Settings" = {
        name = "Paramètres";
        exec = "gnome-control-center";
        type = "Application";
        noDisplay = true;
      };
      "org.gnome.Extensions" = {
        name = "Extensions";
        exec = null;
        type = "Application";
        noDisplay = true;
      };
      "org.gnome.Shell.Extensions" = {
        name = "Extensions";
        exec = "gnome-extensions-app";
        type = "Application";
        noDisplay = true;
      };
      "gnome-printers-panel" = {
        name = "Imprimantes";
        exec = "gnome-control-center printers";
        type = "Application";
        noDisplay = true;
      };
      "org.gnome.FileRoller" = {
        name = "File Roller";
        exec = "file-roller %U";
        type = "Application";
        noDisplay = true;
      };
    };
  };
}
