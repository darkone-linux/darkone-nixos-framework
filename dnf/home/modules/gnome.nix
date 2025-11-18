# Gnome tweaks for home manager.

{ lib, config, ... }:

let
  cfg = config.darkone.home.gnome;
  #hasNFS = (nfsServerCount = lib.count (s: s.service == "nfs") osConfig.network.sharedServices) == 1;
in
{
  options = {
    darkone.home.gnome.enable = lib.mkEnableOption "Enable gnome settings for home manager";
    darkone.home.gnome.hideTechnicalIcons = lib.mkEnableOption "Hide some icons for beginners / children / babies";
  };

  config = lib.mkIf cfg.enable {

    #TODO: gtk.gtk3.bookmarks = lib.optionals hasNFS [ "file:///home/${config.home.username}/Documents" ];

    # # Gnome general settings (no effect?)
    # gtk = {
    #   enable = true;
    #   colorScheme = "dark";
    #   cursorTheme = {
    #     package = pkgs.bibata-cursors;
    #     name = "Bibata-Modern-Classic";
    #     size = 48;
    #   };
    #   gtk3 = {
    #     bookmarks = [ "file:///home/${config.home.username}/Documents" ];
    #     colorScheme = "dark";
    #     cursorTheme = {
    #       package = pkgs.bibata-cursors;
    #       name = "Bibata-Modern-Classic";
    #       size = 48;
    #     };
    #     iconTheme = {
    #       package = pkgs.papirus-icon-theme;
    #       name = "Papirus-Dark";
    #     };
    #   };
    #   gtk4.extraConfig = {
    #     gtk-application-prefer-dark-theme = 1;
    #   };
    # };
    # # QT specific configuration
    # qt = {
    #   enable = true;
    #   platformTheme.name = "gtk3";
    #   style = {
    #     name = "adwaita-dark";
    #     package = pkgs.adwaita-qt;
    #   };
    # };

    # Hide icons
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
