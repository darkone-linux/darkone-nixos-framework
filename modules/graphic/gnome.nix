# Pre-configured gnome environment with dependences.

{
  lib,
  config,
  pkgs,
  host,
  network,
  ...
}:
with lib;
let
  cfg = config.darkone.graphic.gnome;
  hasInternalCloud =
    (findFirst (s: s.name == "nextcloud" || s.name == "oxicloud") null network.services) != null;
in
{
  options = {
    darkone.graphic.gnome.enable = mkEnableOption "Pre-configured gnome WM";
    darkone.graphic.gnome.enableDashToDock = mkEnableOption "Dash to dock plugin";
    darkone.graphic.gnome.enableLightDM = mkEnableOption "Enable LightDM instead of GDM";
    darkone.graphic.gnome.enableCaffeine = mkEnableOption "Disable auto-suspend";
    darkone.graphic.gnome.enableGsConnect = mkEnableOption "Communication with devices";
    darkone.graphic.gnome.enableOnlineServices = mkEnableOption "Online Accounts, CalDAV, CardDAV...";
    darkone.graphic.gnome.xkbVariant = mkOption {
      type = types.str;
      default = "oss";
      description = "Keyboard variant. Layout is extracted from console keymap.";
    };
    darkone.graphic.gnome.screenBlankDelay = mkOption {
      type = types.ints.unsigned;
      default = 1800;
      description = "Screen-blank delay in seconds (0 = never). Laptops override it to 900 (15 min).";
    };
  };

  config = mkIf cfg.enable {

    # Enable gnome
    services.desktopManager.gnome.enable = true;

    #==========================================================================
    # XSERVER SETTINGS
    #==========================================================================

    services.xserver = {

      # Enable the X11 windowing system.
      enable = true;

      # Configure keymap in X11
      # Type `localectl list-x11-keymap-variants` to list variants
      xkb = {
        layout = config.console.keyMap;
        variant = cfg.xkbVariant;
        model = "pc105";
      };

      # Video drivers
      videoDrivers = [
        "modesetting"
        "fbdev"
        "amdgpu"
        "intel"
        #"nvidia"
      ];

      # LightDM options if activated
      displayManager.lightdm = mkIf cfg.enableLightDM {
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
    };

    environment.variables = {
      XKB_DEFAULT_LAYOUT = config.services.xserver.xkb.layout;
      XKB_DEFAULT_VARIANT = config.services.xserver.xkb.variant;
      XKB_DEFAULT_MODEL = config.services.xserver.xkb.model;
    };

    #==========================================================================
    # GDM SETTINGS
    #==========================================================================

    # GDM options if activated
    services.displayManager.gdm = mkIf (!cfg.enableLightDM) {
      enable = true;
      autoSuspend = config.darkone.system.core.enableAutoSuspend;
      settings = {
        greeter = {

          # https://help.gnome.org/admin/gdm/stable/configuration.html.en#greetersection
          IncludeAll = false;
          Exclude = "nix,bin,root,daemon,adm,lp,sync,shutdown,halt,mail,news,uucp,operator,nobody,nobody4,noaccess,postgres,pvm,nfsnobody,pcap";
        };
      };
    };

    # Keep the active graphical session alive across rebuilds: restarting the
    # display-manager unit tears down the running Wayland/X session and logs the
    # user out on every `switch`/`test`. A display-manager change applies on the
    # next reboot instead.
    systemd.services.display-manager.restartIfChanged = false;

    #==========================================================================
    # GNOME DEFAULT APPLICATIONS & SERVICES
    #==========================================================================

    # Enable networking with networkmanager
    networking.networkmanager.enable = true;

    # Remove unused gnome packages
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
      gnome-console
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
      gnome-user-share
      gnome-weather
      hitori
      iagno
      loupe
      simple-scan
      snapshot
      showtime
      tali
      totem
      xterm
      yelp
    ];

    # Gnome packages
    environment.systemPackages = with pkgs; [
      (mkIf cfg.enableCaffeine gnomeExtensions.caffeine)
      (mkIf cfg.enableDashToDock gnomeExtensions.dash-to-dock)
      (mkIf cfg.enableGsConnect gnomeExtensions.gsconnect)
      bibata-cursors
      gnomeExtensions.appindicator
      gnomeExtensions.just-perfection

      # Force focus + raise on newly mapped windows. Works around Mutter's
      # focus-stealing prevention (apps launched from notifications or tray
      # indicators open unfocused, with a bouncing dash icon instead).
      gnomeExtensions.steal-my-focus-window

      papirus-icon-theme
      adwaita-qt
      qgnomeplatform-qt6
    ];

    # DO NOT TO THAT - break the gnome theme
    # environment.sessionVariables = {
    #   GTK_THEME = "Adwaita:dark";
    # };

    # Force QT dark theme
    qt = {
      enable = true;
      style = "adwaita-dark";
      platformTheme = "gnome";
    };

    # Devices connections
    programs.kdeconnect = mkIf cfg.enableGsConnect {
      enable = true;
      package = pkgs.gnomeExtensions.gsconnect;
    };

    # Gnome services
    services.gnome = {
      gnome-online-accounts.enable = hasInternalCloud || cfg.enableOnlineServices; # Nextcloud, etc.
      evolution-data-server.enable = hasInternalCloud || cfg.enableOnlineServices; # CalDAV, CardDAV, tasks
      gnome-settings-daemon.enable = true;
      gnome-user-share.enable = false;
      glib-networking.enable = true; # HTTPS, proxy, authentification support
      localsearch.enable = true;
      sushi.enable = true; # Files preview in Nautilus
    };

    # LocalSearch (ex-Tracker) flushe sa base sur SIGTERM et peut retenir
    # user@.service jusqu'à 90 s au halt (indexation lourde sur postes dev).
    # Il journalise sa progression et reprend au boot suivant : on borne son
    # arrêt à 5 s pour ne pas retarder l'extinction (pire cas = ré-index
    # incrémental des fichiers modifiés entre-temps).
    systemd.user.services.localsearch-3 = {
      overrideStrategy = "asDropin";
      serviceConfig.TimeoutStopSec = 5;
    };

    #==========================================================================
    # DCONF SETTINGS
    #==========================================================================

    programs.dconf = {
      enable = true;
      profiles = {

        # Gnome settings
        # -> https://github.com/nix-community/dconf2nix
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
                gtk-theme = "Adw-dark"; # not Adwaita-dark
                color-scheme = "prefer-dark";
                gtk-enable-primary-paste = true; # Middle-click paste (PRIMARY selection)
                monospace-font-name = "JetBrainsMono Nerd Font Mono 16";
                enable-hot-corners = false; # Disable hot-corner actions when the cursor reaches a screen corner
              };
              "org/gnome/desktop/background" = {
                # Reference to a file in the store:
                # https://github.com/NixOS/nixpkgs/blob/18bcb1ef6e5397826e4bfae8ae95f1f88bf59f4f/nixos/modules/services/x11/desktop-managers/gnome.nix#L36
                picture-uri-dark = "${pkgs.nixos-artwork.wallpapers.simple-blue.gnomeFilePath}";
              };
              "org/gnome/desktop/wm/keybindings" = {

                # Flat window switching only: every shortcut cycles individual
                # windows. The app-grouped switcher hides instances behind one
                # icon (must hover to reveal them), so it is disabled.
                switch-applications = [ ];
                switch-applications-backward = [ ];
                switch-windows = [
                  "<Super>Tab"
                  "<Alt>Tab"
                ];
                switch-windows-backward = [
                  "<Shift><Super>Tab"
                  "<Shift><Alt>Tab"
                ];
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

                # Lock the session as soon as the screen blanks: re-login
                # is required to wake it (display off only, not system suspend)
                lock-enabled = true;
                lock-delay = gvariant.mkUint32 0;
              };
              "org/gnome/shell" = {
                disable-user-extensions = false;
                enabled-extensions = [
                  "appindicatorsupport@rgcjonas.gmail.com"
                  "blur-my-shell@aunetx"
                  "steal-my-focus-window@steal-my-focus-window"
                ]
                ++ (if cfg.enableCaffeine then [ "caffeine@patapon.info" ] else [ ])
                ++ (if cfg.enableGsConnect then [ "gsconnect@andyholmes.github.io" ] else [ ])
                ++ (if cfg.enableDashToDock then [ "dash-to-dock@micxgx.gmail.com" ] else [ ]);
                favorite-apps = [
                  "org.gnome.Console.desktop"
                  "com.mitchellh.ghostty.desktop"
                  "brave-browser.desktop"
                  "com.brave.Browser.desktop"
                  "chromium-browser.desktop"
                  "firefox.desktop"
                  "firefox-esr.desktop"
                  "librewolf.desktop"
                  "obsidian.desktop"
                  "code.desktop"
                  "dev.zed.Zed.desktop"
                  "org.gnome.TextEditor.desktop"
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
              "org/gnome/settings-daemon/plugins/power" = {
                sleep-inactive-ac-timeout = gvariant.mkUint32 1800;
                sleep-inactive-ac-type = "nothing";
                sleep-inactive-battery-timeout = gvariant.mkUint32 1800;
                sleep-inactive-battery-type = "suspend";
              };
              "org/gnome/mutter" = {
                check-alive-timeout = gvariant.mkUint32 30000;
                edge-tiling = true;
              };
              "org/gnome/bluetooth" = {
                powered = false;
              };
              "org/gnome/nautilus/preferences" = {
                show-directory-item-counts = "never";
              };
              "org/gnome/settings-daemon/plugins/sharing" = {
                active = false;
              };

              # Recherche locale : indexe tous les dossiers XDG user-dirs
              # (Desktop, Documents, Download, Music, Pictures, Videos...)
              # + blacklist node_modules, *.ts, *.mts
              "org/freedesktop/tracker/miner/files" = {
                index-recursive-directories = [
                  "&DESKTOP"
                  "&DOCUMENTS"
                  "&DOWNLOAD"
                  "&MUSIC"
                  "&PICTURES"
                  "&PUBLIC_SHARE"
                  "&TEMPLATES"
                  "&VIDEOS"
                ];
                ignored-directories = [
                  "node_modules"
                  "vendor"
                  "po"
                  "CVS"
                  "core-dumps"
                  "lost+found"
                  ".cache"
                ];
                ignored-files = [
                  "*.ts"
                  "*.mts"
                ];
              };
            };
          }

          # User-overridable defaults (no lockAll): lets the user change or
          # disable the screen-blank delay in Settings > Power > Blank Screen
          {
            settings = {

              # Blank the screen after screenBlankDelay seconds (0 = never)
              "org/gnome/desktop/session" = {
                idle-delay = gvariant.mkUint32 cfg.screenBlankDelay;
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
