# Gnome tweaks for home manager.

{ lib, config, ... }:

let
  cfg = config.darkone.home.gnome;
  #hasNFS = (nfsServerCount = lib.count (s: s.name == "nfs" && s.zone == zone.name) osConfig.network.services) == 1;
in
{
  options = {
    darkone.home.gnome.enable = lib.mkEnableOption "Enable gnome settings for home manager";
    darkone.home.gnome.hideTechnicalIcons = lib.mkEnableOption "Hide some icons for beginners / children / babies";
  };

  # NOTE: do not declare gtk.gtk3.bookmarks, "nfs.nix" creates this file!
  config = lib.mkIf cfg.enable {

    # Hide xterm app
    home.file.".local/share/applications/xterm.desktop".text = ''
      [Desktop Entry]
      Name=XTerm
      Comment=Terminal emulator
      Exec=xterm
      Icon=utilities-terminal
      Terminal=true
      Type=Application
      NoDisplay=true
      Categories=System;TerminalEmulator;
    '';

    # Hide icons
    xdg.desktopEntries = lib.mkIf cfg.hideTechnicalIcons {
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
