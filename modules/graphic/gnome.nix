# Pre-configured gnome environment with dependences.
#
# :::note[Login keyring after `just passwd`]
# PAM unlocks the login keyring with the session password, which a change
# made by the admin cannot re-encrypt (the old password is unknown). The next
# password login drops the keyring: GNOME recreates it, empty, on the new
# password. No prompt, and the old password opens nothing anymore.
# :::
#
# :::caution[Keyring secrets lost on each admin password change]
# Apps ask once again for their credentials. Opt-out, for a keyring with a
# password of its own: `darkone.home.gnome.keepKeyring`.
# :::

{
  lib,
  config,
  pkgs,
  host,
  network,
  ...
}:
let
  inherit (lib)
    concatStringsSep
    escapeShellArg
    filterAttrs
    findFirst
    gvariant
    mapAttrsToList
    mkAfter
    mkEnableOption
    mkForce
    mkIf
    mkOption
    types
    ;
  cfg = config.darkone.graphic.gnome;
  hasInternalCloud =
    (findFirst (s: s.name == "nextcloud" || s.name == "oxicloud") null network.services) != null;

  # Keyring reset (cf. header): accounts whose session password comes from a
  # declared hash file (`just passwd`), minus the per-user opt-outs.
  keyringResetUsers = filterAttrs (
    login: user:
    user.isNormalUser
    && user.hashedPasswordFile != null
    && !(config.home-manager.users.${login}.darkone.home.gnome.keepKeyring or false)
  ) config.users.users;
  keyringResetCases = concatStringsSep "\n  " (
    mapAttrsToList (
      login: user:
      "${escapeShellArg login}) hashFile=${escapeShellArg user.hashedPasswordFile} home=${escapeShellArg user.home} ;;"
    ) keyringResetUsers
  );

  # Run as root by PAM. One fingerprint of the hash file per account: a new
  # fingerprint means a new password, hence a keyring to drop.
  keyringReset = pkgs.writeShellScript "keyring-reset" ''
    set -euo pipefail
    umask 077

    case "''${PAM_USER:-}" in
      ${keyringResetCases}
      *) exit 0 ;;
    esac
    uid=$(${pkgs.coreutils}/bin/id -u -- "$PAM_USER")
    gid=$(${pkgs.coreutils}/bin/id -g -- "$PAM_USER")

    # A running daemon (screen unlock, second session) holds the keyring:
    # never delete under it, the next login retries
    [ ! -S "/run/user/$uid/keyring/control" ] || exit 0
    [ -r "$hashFile" ] || exit 0

    fingerprint=$(${pkgs.coreutils}/bin/sha256sum < "$hashFile")
    fingerprint=''${fingerprint%% *}
    stamp=/var/lib/keyring-reset/$PAM_USER

    # Files of the user's home are handled as the user: no symlink there can
    # make root read or delete anything else
    asUser() {
      ${pkgs.util-linux}/bin/setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "$@"
    }

    if [ -e "$stamp" ]; then
      [ "$(${pkgs.coreutils}/bin/cat "$stamp")" != "$fingerprint" ] || exit 0
      keyrings=$home/.local/share/keyrings

      # A keyring with no password (plain ini, `[keyring]` header, cf.
      # `darkone.home.umi`) is not tied to the session password: kept
      magic=$(asUser ${pkgs.coreutils}/bin/head -c 9 -- "$keyrings/login.keyring" 2>/dev/null) || magic=absent
      if [ "$magic" != absent ] && [ "$magic" != "[keyring]" ]; then
        asUser ${pkgs.coreutils}/bin/rm -f -- "$keyrings/login.keyring" "$keyrings/user.keystore"
        ${pkgs.util-linux}/bin/logger -t keyring-reset -p authpriv.notice \
          "$PAM_USER: session password changed, login keyring dropped"
      fi
    else

      # First sight records only: the rollout drops no keyring
      ${pkgs.coreutils}/bin/mkdir -p /var/lib/keyring-reset
    fi
    printf '%s\n' "$fingerprint" > "$stamp"
  '';
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
    darkone.graphic.gnome.cursorSize = mkOption {
      type = types.ints.positive;
      default = 24;
      description = "Default pointer size in pixels, user-overridable (Settings > Accessibility).";
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

    # Keyring reset (cf. header): after the password prompt, before
    # `pam_gnome_keyring` stashes it. Key (`pam_u2f`) and autologin sessions
    # never get there, they bring no password to recreate the keyring with.
    security.pam.services.login.rules.auth.keyring-reset = {
      enable = config.security.pam.services.login.enableGnomeKeyring;
      control = "optional";
      modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
      order = config.security.pam.services.login.rules.auth.gnome_keyring.order - 10;

      # `quiet`: a failure never reaches the greeter
      settings = {
        quiet = true;
        type = "auth";
      };
      args = mkAfter [ "${keyringReset}" ];
    };

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
      #gnomeExtensions.appindicator # Old one
      gnomeExtensions.status-tray # New one
      gnomeExtensions.just-perfection

      # Force focus + raise on newly mapped windows. Works around Mutter's
      # focus-stealing prevention (apps launched from notifications or tray
      # indicators open unfocused, with a bouncing dash icon instead).
      gnomeExtensions.steal-my-focus-window

      papirus-icon-theme
      adwaita-qt

      # Kept for its Wayland decoration plugin alone, opt-in via
      # `QT_WAYLAND_DECORATION=qgnomeplatform`; its platform theme is
      # deliberately not selected, see `qt.platformTheme` below.
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
      platformTheme = "qt5ct"; # More efficient than "gnome", todo: qt6ct (not available for the moment)
    };

    # Devices connections
    programs.kdeconnect = mkIf cfg.enableGsConnect {
      enable = true;
      package = pkgs.gnomeExtensions.gsconnect;
    };

    # Gnome services
    services.gnome = {
      gnome-online-accounts.enable = hasInternalCloud || cfg.enableOnlineServices; # Nextcloud, etc.

      # mkForce: the upstream GNOME desktop-manager sets this one without
      # mkDefault, so a fleet with no internal cloud would fail to evaluate.
      evolution-data-server.enable = mkForce (hasInternalCloud || cfg.enableOnlineServices); # CalDAV, CardDAV, tasks
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
                switch-applications = gvariant.mkEmptyArray gvariant.type.string;
                switch-applications-backward = gvariant.mkEmptyArray gvariant.type.string;
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
                  #"appindicatorsupport@rgcjonas.gmail.com" # old one
                  "status-tray@keithvassallo.com" # new one
                  "blur-my-shell@aunetx"
                  "steal-my-focus-window@steal-my-focus-window"
                ]
                ++ (if cfg.enableCaffeine then [ "caffeine@patapon.info" ] else [ ])
                ++ (if cfg.enableGsConnect then [ "gsconnect@andyholmes.github.io" ] else [ ])
                ++ (if cfg.enableDashToDock then [ "dash-to-dock@micxgx.gmail.com" ] else [ ]);

                # No `org.gnome.Console.desktop`: gnome-console is the terminal
                # of non-technical profiles, kept off their dash (still in the
                # app grid). Technical profiles get Ghostty.
                favorite-apps = [
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

                # Notification counter badges: a single terminal bell raises
                # one and it never clears, so the number means nothing. The
                # message tray already carries the information — same reason
                # visual-bell and event-sounds are off above.
                show-icons-notifications-counter = false;

                show-mounts-network = true;
              };
              "org/gnome/shell/extensions/status-tray" = {
                icon-mode = "original";
              };
              "org/gnome/settings-daemon/plugins/power" = {
                sleep-inactive-ac-timeout = gvariant.mkUint32 1800;
                sleep-inactive-ac-type = "nothing";
                sleep-inactive-battery-timeout = gvariant.mkUint32 1800;

                # gnome-settings-daemon suspends on its own schedule, whatever
                # logind was told: a host that must stay reachable cannot let it
                # (the greeter side is handled by `gdm.autoSuspend` above).
                sleep-inactive-battery-type =
                  if config.darkone.system.core.enableAutoSuspend then "suspend" else "nothing";
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

              # "Support GNOME" notification, raised periodically by gsd-housekeeping
              "org/gnome/settings-daemon/plugins/housekeeping" = {
                donation-reminder-enabled = false;
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

          # User-overridable defaults (no lockAll): Settings or a home module
          # may change them per user
          {
            settings = {

              # Blank the screen after screenBlankDelay seconds (0 = never)
              "org/gnome/desktop/session" = {
                idle-delay = gvariant.mkUint32 cfg.screenBlankDelay;
              };

              # An a11y setting: the UMI home raises it for its user only,
              # other users of the same host keep this default
              "org/gnome/desktop/interface" = {
                cursor-size = gvariant.mkInt32 cfg.cursorSize;
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
