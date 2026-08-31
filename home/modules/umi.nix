# Home module: gaze-driven input (Talon autostart + Onboard tuned for eye tracking).
#
# :::note[Pairs with the umi host profile]
# The host must provide udev/uinput and the Cinnamon X11 session (see
# `darkone.host.umi`). This module configures the user side: opt-in dwell
# click (`enableDwell`), always-visible docked Onboard keyboard with word
# prediction and sticky modifiers, and Talon session autostart.
# :::
#
# :::tip[Community scripts]
# Set `communityScripts` to a fetched github:talonhub/community tree to get
# full gaze mouse control (zoom mouse, pop click) declaratively.
# :::
#
# :::note[Dual schemas]
# The gaze session is Cinnamon (org/cinnamon/*) but the GNOME keys
# (org/gnome/*) are kept in sync: mousetweaks reads the GNOME a11y schema,
# and they serve as fallback if the user ever lands in a GNOME session.
# Exception: keys locked by the DNF gnome module are never mirrored here,
# a write to a locked key aborts the whole home-manager `dconf load`.
# Screen locking stays enabled GNOME-side (locked by the DNF gnome module);
# `idle-delay = 0` avoids triggering it, and the Cinnamon session has its
# own lock fully disabled.
# :::
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.home.umi;

  # Dwell click parameters shared by the GNOME and Cinnamon a11y schemas. The
  # toggles are written even when disabled: leaving the keys out would keep a
  # previously enabled dwell click alive in the user's dconf database.
  dwellSettings = {
    dwell-click-enabled = cfg.enableDwell;
    dwell-time = cfg.dwellTime;
    dwell-threshold = 15;
    secondary-click-enabled = cfg.enableDwell;
  };

  # Big cursor and text for gaze precision (~15-30 px). `cursor-size` is
  # absent from the GNOME set on purpose: the DNF gnome module locks
  # /org/gnome/desktop/interface/cursor-size host-wide at the same value,
  # and a write to a locked key aborts the whole `dconf load` at activation.
  interfaceSettings = {
    text-scaling-factor = 1.25;
  };

  # gnome-keyring's on-disk format for a keyring with no password: plain ini
  # instead of the encrypted blob, unlocked at startup without a prompt.
  plainLoginKeyring = pkgs.writeText "login.keyring" ''
    [keyring]
    display-name=login
    ctime=0
    mtime=0
    lock-on-idle=false
    lock-after=false
  '';
  defaultKeyringName = pkgs.writeText "default-keyring" "login";
in
{
  options = {
    darkone.home.umi = {
      enable = lib.mkEnableOption "Gaze-driven input configuration (Talon + Onboard)";
      enableTalonAutostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Start Talon on session login (talon must be in PATH).";
      };
      communityScripts = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "talonhub/community tree deployed to ~/.talon/user/community.";
      };
      enableDwell = lib.mkEnableOption ''
        dwell click: clicking by resting the pointer. Off by default — it is
        only usable with an eye tracker, and with a mouse it fires on whatever
        the pointer was left over (the a11y menu toggling zoom or the on-screen
        keyboard, typically)
      '';
      dwellTime = lib.mkOption {
        type = lib.types.float;
        default = 1.2;
        description = "Dwell click delay in seconds.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    home.packages = [ pkgs.onboard ];

    # Declarative Talon user scripts
    home.file.".talon/user/community" = lib.mkIf (cfg.communityScripts != null) {
      source = cfg.communityScripts;
      recursive = true;
    };

    # Session autostart (XDG, honored by Cinnamon): Talon then Onboard
    xdg.configFile."autostart/talon.desktop" = lib.mkIf cfg.enableTalonAutostart {
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Talon
        Exec=talon
        X-GNOME-Autostart-enabled=true
      '';
    };
    xdg.configFile."autostart/onboard.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Onboard
      Exec=onboard
      X-GNOME-Autostart-enabled=true
    '';

    dconf.settings = {

      # Dwell click (both schema families, cf. header)
      "org/cinnamon/desktop/a11y/mouse" = dwellSettings;
      "org/gnome/desktop/a11y/mouse" = dwellSettings;
      "org/cinnamon/desktop/interface" = interfaceSettings // {
        cursor-size = 48;
      };
      "org/gnome/desktop/interface" = interfaceSettings;
      "org/gnome/desktop/a11y" = {
        always-show-universal-access-status = true;
      };

      # A lock screen is a dead-end without a keyboard: disable Cinnamon
      # locking entirely and never let the session go idle. The GNOME
      # `lock-enabled` key is locked host-wide by the DNF gnome module, so
      # only `idle-delay = 0` (user-overridable) protects a GNOME fallback
      # session.
      "org/cinnamon/desktop/screensaver" = {
        lock-enabled = false;
        idle-activation-enabled = false;
      };
      "org/cinnamon/desktop/session".idle-delay = lib.hm.gvariant.mkUint32 0;
      "org/gnome/desktop/session".idle-delay = lib.hm.gvariant.mkUint32 0;

      # Onboard tuned for gaze input: fixed docked position, big
      # high-contrast targets, sticky modifiers (no key holding with eyes),
      # word prediction to reduce dwell count, jitter tolerance.
      "org/onboard" = {
        layout = "Full Keyboard";
        theme = "HighContrast";
        use-system-defaults = false;
      };
      "org/onboard/window" = {
        docking-enabled = true;
        docking-edge = "bottom";
        force-to-top = true;
        window-decoration = false;
        transparency = 0.0;
      };
      "org/onboard/auto-show".enabled = false;
      "org/onboard/keyboard" = {
        long-press-delay = 2.0;
        touch-feedback-enabled = true;
        audio-feedback-enabled = true;
      };
      "org/onboard/typing-assistance".auto-capitalization = true;
      "org/onboard/typing-assistance/word-suggestions" = {
        enabled = true;
        delayed-word-separators-enabled = true;
        spelling-suggestions-enabled = true;
      };
      "org/onboard/universal-access" = {
        hide-click-type-window = false;
        enable-click-type-window-on-exit = true;
        drag-threshold = 20;
      };
    };

    # Configuration panels a gaze user cannot act on. A `NoDisplay` entry in
    # ~/.local/share/applications shadows the system one (XDG precedence);
    # the packages themselves are Cinnamon/GNOME internals, not removable.
    xdg.desktopEntries = {
      cinnamon-settings-actions = {
        name = "Actions";
        exec = "cinnamon-settings actions";
        type = "Application";
        noDisplay = true;
      };
      cinnamon-settings-extensions = {
        name = "Extensions";
        exec = "cinnamon-settings extensions";
        type = "Application";
        noDisplay = true;
      };
      "org.gnome.Extensions" = {
        name = "Extensions";
        exec = "gnome-extensions-app";
        type = "Application";
        noDisplay = true;
      };
    };

    # Cinnamon's stock panel pins name `firefox.desktop`, DNF ships Firefox ESR
    # as `firefox-esr.desktop`: the pin resolves to nothing and the launcher is
    # silently dropped, leaving only Files and Terminal. Rewrite the id in
    # place rather than forcing the whole list, so pins added later survive.
    # The file only exists once Cinnamon has run: on a fresh home the fix
    # lands on the activation that follows the first login.
    home.activation.gazePanelLaunchers = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      for cfgFile in "$HOME"/.config/cinnamon/spices/grouped-window-list@cinnamon.org/*.json ; do
        [ -e "$cfgFile" ] || continue
        ${pkgs.jq}/bin/jq '."pinned-apps".value |= map(
          if . == "firefox.desktop" then "firefox-esr.desktop" else . end
        )' "$cfgFile" > "$cfgFile.new" || continue
        run ${pkgs.coreutils}/bin/mv -f "$cfgFile.new" "$cfgFile"
      done
    '';

    # An autologin session never types a password, so PAM cannot hand one to
    # gnome-keyring: every secret-using app pops a gcr prompt that a gaze user
    # cannot answer. Seed an empty-password login keyring, which gnome-keyring
    # stores unencrypted and unlocks on its own. Only written when absent — an
    # existing keyring may hold secrets and is never replaced.
    home.activation.gazeLoginKeyring = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      keyringDir="$HOME/.local/share/keyrings"
      if [ ! -e "$keyringDir/login.keyring" ] ; then
        run ${pkgs.coreutils}/bin/mkdir -p -m 700 "$keyringDir"
        run ${pkgs.coreutils}/bin/install -m 600 ${plainLoginKeyring} "$keyringDir/login.keyring"
        run ${pkgs.coreutils}/bin/install -m 600 ${defaultKeyringName} "$keyringDir/default"
      fi
    '';
  };
}
