# Gnome tweaks for home-manager.
#
# Hides the bare `xterm`, Qt5/Qt6 settings and NixOS manual launchers
# unconditionally, Extensions for non-technical profiles, registers polished
# `.desktop` entries for `scrcpy` and `scrcpy-console` when the package is
# part of the user's `home.packages`, and (when `hideTechnicalIcons` is set)
# hides Settings, Printers and File Roller icons for beginner / child profiles.
#
# :::caution[NFS bookmarks]
# Do not declare `gtk.gtk3.bookmarks` from this module — while NFS home shares
# are on, `home/profiles/minimal/nfs.nix` owns this file and overwrites it.
# :::

{
  lib,
  config,
  pkgs,
  ...
}:

let
  cfg = config.darkone.home.gnome;
in
{
  options = {
    darkone.home.gnome.enable = lib.mkEnableOption "Enable gnome settings for home manager";
    darkone.home.gnome.hideTechnicalIcons = lib.mkEnableOption "Hide some icons for beginners / children / babies";
  };

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

    # Useless icons
    home.file.".local/share/applications/scrcpy.desktop" =
      lib.mkIf (lib.elem pkgs.scrcpy config.home.packages)
        {
          text = ''
            [Desktop Entry]
            Name=scrcpy
            GenericName=Android Remote Control
            Comment=Display and control your Android device
            Exec=/bin/sh -c "\\$SHELL -i -c scrcpy"
            Icon=scrcpy
            Terminal=false
            Type=Application
            NoDisplay=true
            Categories=Utility;RemoteAccess;
            StartupNotify=false
          '';
        };
    home.file.".local/share/applications/scrcpy-console.desktop" =
      lib.mkIf (lib.elem pkgs.scrcpy config.home.packages)
        {
          text = ''
            [Desktop Entry]
            Name=scrcpy (console)
            GenericName=Android Remote Control
            Comment=Display and control your Android device
            Exec=/bin/sh -c "\\$SHELL -i -c 'scrcpy --pause-on-exit=if-error'"
            Icon=scrcpy
            Terminal=true
            Type=Application
            NoDisplay=true
            Categories=Utility;RemoteAccess;
            StartupNotify=false
          '';
        };

    # Extensions app, hidden for non-technical profiles. Must live in
    # XDG_DATA_HOME: the gnome-shell wrapper prepends its own `share/` to
    # XDG_DATA_DIRS, shadowing any `xdg.desktopEntries` override.
    home.file.".local/share/applications/org.gnome.Extensions.desktop" =
      lib.mkIf (!config.darkone.home.advanced.enable)
        {
          text = ''
            [Desktop Entry]
            Name=Extensions
            Exec=gnome-extensions-app
            Icon=org.gnome.Extensions
            Type=Application
            NoDisplay=true
          '';
        };

    xdg.desktopEntries = lib.mkMerge [

      # Hidden for every profile: `qt5ct`/`qt6ct` come with
      # `qt.platformTheme = "qt5ct"` (style forced by `qt.style`), the manual
      # with `documentation.nixos` (still reachable through `nixos-help`).
      {
        qt5ct = {
          name = "Qt5 Settings";
          exec = "qt5ct";
          noDisplay = true;
        };
        qt6ct = {
          name = "Qt6 Settings";
          exec = "qt6ct";
          noDisplay = true;
        };
        nixos-manual = {
          name = "NixOS Manual";
          exec = "nixos-help";
          noDisplay = true;
        };
      }

      # Hidden for beginners / children
      (lib.mkIf cfg.hideTechnicalIcons {
        "org.gnome.Settings" = {
          name = "Paramètres";
          exec = "gnome-control-center";
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
      })
    ];
  };
}
