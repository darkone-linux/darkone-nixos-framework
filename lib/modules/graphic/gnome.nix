{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.gnome;
in
{
  options = {
    darkone.graphic.gnome.enable = lib.mkEnableOption "Pre-configured gnome WM";
    darkone.graphic.gnome.enableDashToDock = lib.mkEnableOption "Dash to dock plugin";
    darkone.graphic.gnome.enableGDM = lib.mkEnableOption "Enable GDM instead of LightDM";
    darkone.graphic.gnome.enableAddExt = lib.mkEnableOption "Additional extensions";
  };

  config = lib.mkIf cfg.enable {

    # Enable the X11 windowing system.
    services.xserver.enable = true;

    # Configure keymap in X11
    # TODO: get theses informations in i18n configuration
    services.xserver.xkb = {
      layout = "fr";
      variant = "azerty";
    };

    # Enable the GNOME Desktop Environment.
    #services.xserver.displayManager.gdm.enable = true;
    services.xserver.displayManager.lightdm = lib.mkIf (!cfg.enableGDM) {
      enable = true;
      greeters.gtk = {
        enable = true;
        indicators = [
          "~host"
          "~spacer"
          "~clock"
          "~spacer"
          "~power"
        ];
      };
    };
    services.xserver.displayManager.gdm.enable = cfg.enableGDM;
    services.xserver.desktopManager.gnome.enable = true;

    # Disable the GNOME3/GDM auto-suspend feature that cannot be disabled in GUI!
    # If no user is logged in, the machine will power down after 20 minutes.
    systemd.targets.sleep.enable = lib.mkDefault false;
    systemd.targets.suspend.enable = lib.mkDefault false;
    systemd.targets.hibernate.enable = lib.mkDefault false;
    systemd.targets.hybrid-sleep.enable = lib.mkDefault false;

    # Enable networking with networkmanager
    networking.networkmanager.enable = true;

    # Nerd fond for gnome terminal and default monospace
    fonts.packages = with pkgs; [ nerd-fonts.jetbrains-mono ];
    fonts.fontconfig.enable = true;

    # Suppression des paquets gnome inutiles
    environment.gnome.excludePackages = with pkgs; [
      atomix
      epiphany
      geary
      gnome-backgrounds
      gnome-calendar
      gnome-clocks
      gnome-contacts
      gnome-font-viewer
      gnome-logs
      gnome-maps
      gnome-music
      gnome-packagekit
      gnome-software
      gnome-tour
      gnome-user-docs
      gnome-weather
      hitori
      iagno
      loupe
      simple-scan
      tali
      totem
      yelp
      xterm
    ];

    # Gnome packages
    environment.systemPackages = with pkgs; [
      bibata-cursors
      papirus-icon-theme
      gnomeExtensions.appindicator
      (lib.mkIf cfg.enableAddExt gnomeExtensions.caffeine)
      (lib.mkIf cfg.enableAddExt gnomeExtensions.gsconnect)
      (lib.mkIf cfg.enableDashToDock gnomeExtensions.dash-to-dock)
    ];

    # Communication avec les devices
    programs.kdeconnect = {
      enable = true;
      package = pkgs.gnomeExtensions.gsconnect;
    };

    # Personnalisation de gnome
    programs.dconf = {
      enable = true;
      profiles.user.databases = [
        {
          lockAll = true; # prevents overriding
          settings = {
            "org/gnome/desktop/wm/preferences" = {
              button-layout = "appmenu:minimize,maximize,close";
              #theme = "adw-gtk3";
              focus-mode = "click";
              visual-bell = false;
            };
            "org/gnome/desktop/interface" = {
              cursor-theme = "Bibata-Modern-Classic";
              cursor-size = "48";
              icon-theme = "Papirus-Dark";
              gtk-theme = "Adw-dark";
              color-scheme = "prefer-dark"; # Dark par défaut
              monospace-font-name = "JetBrainsMono Nerd Font Mono 16"; # Fonte mono par défaut
              enable-hot-corners = false; # Suppression des actions quand le curseur arrive dans un coin
            };
            "org/gnome/desktop/background" = {
              # Référence à un fichier dans le store :
              # https://github.com/NixOS/nixpkgs/blob/18bcb1ef6e5397826e4bfae8ae95f1f88bf59f4f/nixos/modules/services/x11/desktop-managers/gnome.nix#L36
              picture-uri-dark = "${pkgs.nixos-artwork.wallpapers.simple-blue.gnomeFilePath}";
            };
            "org/gnome/desktop/wm/keybindings" = {
              switch-applications = [ "<Super>Tab" ];
              switch-applications-backward = [ "<Shift><Super>Tab" ];
              switch-windows = [ "<Alt>Tab" ];
              switch-windows-backward = [ "<Shift><Alt>Tab" ];
            };
            "org/gnome/desktop/peripherals/touchpad" = {
              click-method = "areas";
              tap-to-click = true;
              two-finger-scrolling-enabled = true;
            };
            "org/gnome/desktop/peripherals/keyboard" = {
              numlock-state = true;
            };
            "org/gnome/shell" = {
              disable-user-extensions = false;
              enabled-extensions = [
                "caffeine@patapon.info"
                "gsconnect@andyholmes.github.io"
                "appindicatorsupport@rgcjonas.gmail.com"
                #"dash-to-dock@micxgx.gmail.com"
              ];
              favorite-apps = [
                "org.gnome.Console.desktop"
                "firefox.desktop"
                "org.gnome.TextEditor.desktop"
                "obsidian.desktop"
                "code.desktop"
                "writer.desktop"
                "calc.desktop"
                "impress.desktop"
                "thunderbird.desktop"
                "org.gnome.Nautilus.desktop"
              ];
            };
            "org/gnome/shell/extensions/dash-to-dock" = {
              click-action = "minimize-or-overview";
              disable-overview-on-startup = true;
              dock-position = "BOTTOM";
              running-indicator-style = "DOTS";
              isolate-monitor = false;
              multi-monitor = true;
              show-mounts-network = true;
              always-center-icons = true;
              custom-theme-shrink = true;
            };
            "org/gnome/settings-daemon/plugins/media-keys" = {
              custom-keybindings = [
                "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
              ];
            };
            "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
              binding = "<Ctrl><Alt>t";
              command = "kgx";
              name = "open-terminal";
            };
            "org/gnome/settings-daemon/plugins/power" = {
              sleep-inactive-ac-timeout = lib.gvariant.mkUint32 1800;
              sleep-inactive-ac-type = "nothing";
              sleep-inactive-battery-timeout = lib.gvariant.mkUint32 1800;
              sleep-inactive-battery-type = "suspend";
            };
            "org/gnome/mutter" = {
              check-alive-timeout = lib.gvariant.mkUint32 30000;
              edge-tiling = true;
            };
          };
        }
      ];
    };
  };
}
