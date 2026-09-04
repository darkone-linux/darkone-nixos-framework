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
#
# :::caution[Login keyring: two modes, decided by the host]
# An autologin session types no password, so PAM has nothing to hand to
# gnome-keyring and every secret-using app pops a gcr prompt the gaze user
# cannot answer. How that is avoided depends on the host:
#
# - **Unencrypted host**: the login keyring is seeded with an empty password,
#   which gnome-keyring stores in plain text and unlocks on its own (it tries
#   an empty password before prompting). Any pre-existing password-protected
#   keyring is deleted — its passphrase is untypable here, so it can only
#   produce the prompt forever. Autologin already grants the whole session to
#   whoever boots the machine, so this costs no real confidentiality.
# - **Encrypted host** (`darkone.system.luks.volumes` non-empty): nothing is
#   seeded. The passphrase typed at boot is cached in the kernel keyring and
#   handed to gnome-keyring by `pam_gdm`, so the keyring stays encrypted with
#   it. This is the only mode that protects the secrets at rest.
#
# Gotcha, encrypted hosts only: rotating the LUKS passphrase (sops value
# changed, `luks-passphrase-sync`) leaves the keyring on the old one — GNOME
# then reports "The password you use to log in to your computer no longer
# matches that of your login keyring". Delete
# `~/.local/share/keyrings/login.keyring` and log in again.
# :::
{
  lib,
  config,
  pkgs,
  osConfig,
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
  # absent from the GNOME set on purpose: the key is locked host-wide by the
  # DNF gnome module (`darkone.host.umi` raises it to 48 there), and a write
  # to a locked key aborts the whole `dconf load` at activation.
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

  # An encrypted host feeds the boot passphrase to gnome-keyring through
  # pam_gdm; seeding a passwordless keyring there would throw that away.
  hostHasLuks = (osConfig.darkone.system.luks.volumes or [ ]) != [ ];
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

    # Passwordless login keyring, for unencrypted hosts only (cf. the header):
    # gnome-keyring tries an empty password before prompting, and stores such a
    # keyring as plain ini instead of an encrypted blob.
    home.activation.gazeLoginKeyring = lib.mkIf (!hostHasLuks) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        keyringDir="$HOME/.local/share/keyrings"
        run ${pkgs.coreutils}/bin/mkdir -p -m 700 "$keyringDir"

        # A keyring that opens without a password starts with `[keyring]`;
        # anything else is the encrypted binary format, locked behind a
        # passphrase nobody can type here. Dropping it is the only way out of
        # the prompt loop. `user.keystore` (PKCS#11 objects) is sealed with the
        # same password and would prompt on its own, so it goes too.
        if [ -e "$keyringDir/login.keyring" ] &&
           [ "$(${pkgs.coreutils}/bin/head -c 9 "$keyringDir/login.keyring")" != "[keyring]" ] ; then
          run ${pkgs.coreutils}/bin/rm -f "$keyringDir/login.keyring" "$keyringDir/user.keystore"
        fi

        if [ ! -e "$keyringDir/login.keyring" ] ; then
          run ${pkgs.coreutils}/bin/install -m 600 ${plainLoginKeyring} "$keyringDir/login.keyring"
        fi

        # Without it, storing a secret in a home that never had a default
        # collection pops the "create a keyring" prompt (cf. home/modules/office.nix).
        if [ ! -e "$keyringDir/default" ] ; then
          run ${pkgs.coreutils}/bin/install -m 600 ${defaultKeyringName} "$keyringDir/default"
        fi
      ''
    );
  };
}
