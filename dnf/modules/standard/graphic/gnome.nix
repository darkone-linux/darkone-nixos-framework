# Pre-configured gnome environment with dependences.

{
  lib,
  config,
  pkgs,
  host,
  ...
}:
let
  cfg = config.darkone.graphic.gnome;
in
{
  options = {
    darkone.graphic.gnome.enable = lib.mkEnableOption "Pre-configured gnome WM";
    darkone.graphic.gnome.enableDashToDock = lib.mkEnableOption "Dash to dock plugin";
    darkone.graphic.gnome.enableLightDM = lib.mkEnableOption "Enable LightDM instead of GDM";
    darkone.graphic.gnome.enableCaffeine = lib.mkEnableOption "Disable auto-suspend";
    darkone.graphic.gnome.enableGsConnect = lib.mkEnableOption "Communication with devices";
    darkone.graphic.gnome.enableSuspend = lib.mkEnableOption "Enable suspend, sleep, hybernate features (usefull for laptops)";
    darkone.graphic.gnome.xkbVariant = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Keyboard variant. Layout is extracted from console keymap.";
    };
  };

  config = lib.mkIf cfg.enable {

    # Enable the X11 windowing system.
    services.xserver.enable = true;

    # Configure keymap in X11
    # Type `localectl list-x11-keymap-variants` to list variants
    services.xserver.xkb = {
      layout = "${config.console.keyMap}";
      variant = cfg.xkbVariant;
    };

    xdg.mime.defaultApplications = {
      "application/pdf" = "evince.desktop";
      "image/*" = [
        "geeqie.desktop"
        "gimp.desktop"
      ];
    };

    # Enable gnome
    services.desktopManager.gnome.enable = true;

    # LightDM options if activated
    services.xserver.displayManager.lightdm = lib.mkIf cfg.enableLightDM {
      enable = true;
      background = "#394999";
      greeters.gtk = {
        enable = true;
        theme.name = "Adwaita-Dark";
        iconTheme.name = "Papirus-Dark";
        cursorTheme.name = "Bibata-Modern-Classic";
        cursorTheme.size = 24;
        indicators = [
          "~host"
          "~spacer"
          "~clock"
          "~spacer"
          "~power"
        ];
      };
    };

    # GDM options if activated
    services.displayManager.gdm = lib.mkIf (!cfg.enableLightDM) {
      enable = true;
      settings = {
        greeter = {

          # https://help.gnome.org/admin/gdm/stable/configuration.html.en#greetersection
          IncludeAll = false;
          Exclude = "nix,bin,root,daemon,adm,lp,sync,shutdown,halt,mail,news,uucp,operator,nobody,nobody4,noaccess,postgres,pvm,nfsnobody,pcap";
        };
      };
    };

    # Disable the GNOME3/GDM auto-suspend feature that cannot be disabled in GUI!
    # If no user is logged in, the machine will power down after 20 minutes.
    systemd.targets = lib.mkIf cfg.enableSuspend {
      sleep.enable = lib.mkDefault false;
      suspend.enable = lib.mkDefault false;
      hibernate.enable = lib.mkDefault false;
      hybrid-sleep.enable = lib.mkDefault false;
    };

    # Enable networking with networkmanager
    networking.networkmanager.enable = true;

    # Suppression des paquets gnome inutiles
    environment.gnome.excludePackages = with pkgs; [
      atomix
      dialect
      decibels
      epiphany
      evince
      geary
      gnome-backgrounds
      gnome-calendar
      gnome-characters
      gnome-clocks
      gnome-calculator
      gnome-connections
      gnome-contacts
      gnome-font-viewer
      gnome-logs
      gnome-maps
      gnome-music
      gnome-packagekit
      gnome-secrets
      gnome-software
      gnome-tour
      gnome-user-docs
      gnome-weather
      hitori
      iagno
      loupe
      simple-scan
      snapshot
      tali
      totem
      xterm
      yelp
    ];

    # Gnome packages
    environment.systemPackages = with pkgs; [
      (lib.mkIf cfg.enableCaffeine gnomeExtensions.caffeine)
      (lib.mkIf cfg.enableDashToDock gnomeExtensions.dash-to-dock)
      (lib.mkIf cfg.enableGsConnect gnomeExtensions.gsconnect)
      bibata-cursors
      gnomeExtensions.appindicator
      papirus-icon-theme
    ];

    # Communication avec les devices
    programs.kdeconnect = lib.mkIf cfg.enableGsConnect {
      enable = true;
      package = pkgs.gnomeExtensions.gsconnect;
    };

    # Personnalisation de gnome
    programs.dconf = {
      enable = true;
      profiles = {
        user.databases = [
          {
            lockAll = true; # prevents overriding
            settings = {
              "org/gnome/desktop/wm/preferences" = {
                button-layout = "appmenu:minimize,maximize,close";
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
              "org/gnome/desktop/screensaver" = {
                logout-enabled = true;
              };
              "org/gnome/shell" = {
                disable-user-extensions = false;
                enabled-extensions = [
                  "appindicatorsupport@rgcjonas.gmail.com"
                  "blur-my-shell@aunetx"
                ]
                ++ (if cfg.enableCaffeine then [ "caffeine@patapon.info" ] else [ ])
                ++ (if cfg.enableGsConnect then [ "gsconnect@andyholmes.github.io" ] else [ ])
                ++ (if cfg.enableDashToDock then [ "dash-to-dock@micxgx.gmail.com" ] else [ ]);
                favorite-apps = [
                  "org.gnome.Console.desktop"
                  "com.brave.Browser.desktop"
                  "chromium-browser.desktop"
                  "firefox.desktop"
                  "firefox-esr.desktop"
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
              "org/gnome/desktop/sound" = {
                event-sounds = false;
              };
              "org/gnome/shell/extensions/dash-to-dock" = {
                always-center-icons = true;
                click-action = "minimize-or-overview";
                custom-theme-shrink = true;
                disable-overview-on-startup = false;
                dock-position = "BOTTOM";
                isolate-monitor = false;
                intellihide = true;
                multi-monitor = true;
                running-indicator-style = "DOTS";
                show-mounts-network = true;
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
              "org/gnome/bluetooth" = {
                powered = false;
              };
            };
          }
        ];

        # GDM Specific settings
        gdm.databases = [
          {
            lockAll = true; # prevents overriding
            settings = {
              "org/gnome/login-screen" = {
                disable-user-list = true;
                banner-message-enable = true;
                banner-message-text = host.name;
              };
              "org/gnome/bluetooth" = {
                powered = false;
              };
            };
          }
        ];
      };
    };
  };
}
