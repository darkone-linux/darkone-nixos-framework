# "Local network" folder of the app grid: nix-admin on the admin host.

{
  lib,
  pkgs,
  config,
  osConfig,
  ...
}:
let
  cfg = config.darkone.home.advanced;
  enable =
    cfg.enable
    && cfg.enableNixAdmin
    && osConfig.darkone.admin.nix.enable
    && osConfig.darkone.graphic.gnome.enable;
  french = lib.hasPrefix "fr_" osConfig.i18n.defaultLocale;
  category = "X-DNF-Network";
  xdgOpen = "${pkgs.xdg-utils}/bin/xdg-open";

  # Added once, after gnome-shell seeded its own folders: a dconf value set
  # before would stop that seeding, and rewrite the user's folders at each
  # activation. Empty list = shell not seeded yet, next login.
  addFolder = pkgs.writeShellScript "dnf-network-folder" ''
    marker="''${XDG_STATE_HOME:-$HOME/.local/state}/dnf/network-folder"
    [ ! -e "$marker" ] || exit 0
    gsettings=${pkgs.glib}/bin/gsettings
    children="$($gsettings get org.gnome.desktop.app-folders folder-children)"
    case "$children" in
      *"'dnf-network'"*) ;;
      "@as []" | "[]") exit 0 ;;
      *) $gsettings set org.gnome.desktop.app-folders folder-children "''${children%]}, 'dnf-network']" ;;
    esac
    folder=org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/dnf-network/
    $gsettings set "$folder" name ${
      lib.escapeShellArg (if french then "Réseau local" else "Local network")
    }
    $gsettings set "$folder" categories "['${category}']"
    $gsettings set "$folder" translate false
    ${pkgs.coreutils}/bin/mkdir -p "''${marker%/*}"
    ${pkgs.coreutils}/bin/touch "$marker"
  '';
in
{
  config = lib.mkIf enable {
    xdg.desktopEntries = {
      dnf-doc = {
        name = "DNF Doc";
        exec = "${xdgOpen} https://darkone-linux.github.io/${if french then "fr" else "en"}/";
        icon = "help-browser";
        categories = [ category ];
      };
      dnf-onboarding = {
        name = "Onboarding";
        exec = "${xdgOpen} ${osConfig.darkone.admin.welcome.page}";
        icon = "user-home";
        categories = [ category ];
      };
      dnf-network-sources = {
        name = "Network Sources";
        exec = "${lib.getExe config.programs.ghostty.package} --working-directory=/etc/nixos";
        icon = "folder-code";
        categories = [ category ];
      };
    };

    xdg.configFile."autostart/dnf-network-folder.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=DNF network folder
      Exec=${addFolder}
      OnlyShowIn=GNOME;
      NoDisplay=true
    '';
  };
}
