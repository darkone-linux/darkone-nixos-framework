# Gnome tweaks for home-manager.
#
# Hides launchers: the bare `xterm`, Qt5/Qt6 settings and NixOS manual for
# every profile, `scrcpy` and `scrcpy-console` when installed, Extensions for
# non-technical profiles, and (`hideTechnicalIcons`) Settings, Printers and
# File Roller for beginner / child profiles. `hiddenApps` (default: vim, btop,
# htop) hides more, entries still launchable by id.
# `keepKeyring` opts the user out of the login keyring reset that follows an
# admin password change (read by the NixOS gnome module).
#
# :::caution[NFS bookmarks]
# Do not declare `gtk.gtk3.bookmarks` from this module — while NFS home shares
# are on, `home/profiles/minimal/nfs.nix` owns this file and overwrites it.
# :::

{
  lib,
  config,
  osConfig,
  pkgs,
  ...
}:

let
  cfg = config.darkone.home.gnome;

  # Full copies with `NoDisplay` forced, as `umi.nix` does: launches by id
  # and file associations keep working. An absent app gets a `Hidden` stub.
  hiddenAppEntries = pkgs.runCommand "gnome-hidden-apps" { } ''
    mkdir -p $out
    for id in ${lib.escapeShellArgs cfg.hiddenApps} ; do
      printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "$id" > "$out/$id"
      for dir in ${osConfig.system.path}/share/applications ${config.home.path}/share/applications ; do
        if [ -e "$dir/$id" ] ; then
          sed -e '/^[[:blank:]]*NoDisplay=/d' -e '/^[[:blank:]]*\[Desktop Entry\]/a NoDisplay=true' "$dir/$id" > "$out/$id"
          break
        fi
      done
    done
  '';
in
{
  options = {
    darkone.home.gnome.enable = lib.mkEnableOption "Enable gnome settings for home manager";
    darkone.home.gnome.hideTechnicalIcons = lib.mkEnableOption "Hide some icons for beginners / children / babies";
    darkone.home.gnome.keepKeyring = lib.mkEnableOption "Keep the login keyring when the admin changes the session password (keyring with a password of its own)";
    darkone.home.gnome.hiddenApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;

      # Terminal programs: a launcher opening them in a terminal is noise
      default = [
        "btop.desktop"
        "htop.desktop"
        "vim.desktop"
      ];
      description = "Desktop entries hidden from the app grid, still launchable by id";
    };
  };

  config = lib.mkIf cfg.enable {

    # One file each: a recursive `applications/` would clash with `umi.nix`
    xdg.dataFile = lib.genAttrs (map (id: "applications/${id}") cfg.hiddenApps) (name: {
      source = "${hiddenAppEntries}/${lib.removePrefix "applications/" name}";
    });

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

    # scrcpy is a CLI tool: its launchers are noise in the app grid
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
