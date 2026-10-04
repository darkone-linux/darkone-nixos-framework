# Unified Multimodal Input (UMI)
#
# Touchscreen + voice + gaze (Talon autostart + Onboard).
#
# :::note[Session depends on the host]
# - **`darkone.host.umi` host**: Cinnamon X11 session (udev, uinput, Talon
#   provided by the host). Talon and a docked Onboard keyboard (word
#   prediction, sticky modifiers) start with the session, the keyboard hidden
#   until asked for. Panel, icons and text enlarged for gaze targets
#   (`panelHeight`, `textScaling`). DNF panel (`enablePanel`): launchers | open
#   windows, then hover click types, pause zone, gaze switch (applet
#   `umi-mouse`), accessibility menu, Onboard toggle.
# - **Any other host**: GNOME Wayland with its native accessibility: on-screen
#   keyboard, big pointer and text. Talon and Onboard, X11-only, stay off.
#
# Dwell click: opt-in (`enableDwell`) under GNOME. In Cinnamon, a Talon user
# script makes it follow the eye tracker, with gaze control (`enableTrackerAuto`).
# Talon 0.4 and 1.0 alike; 1.0's "Always On" is switched off, the tracker goes
# dark with gaze control.
# :::
#
# :::note[Gaze-only pointing (Talon 1.0)]
# Talon's filters freeze the cursor ~2 mm short of the gaze: the script raises
# them (`gazeFilterSpeed`, `cursorFilterSpeed`, measured on a Tobii 5). Eye
# Tracking menu modes are declared (`enableGazeControl`, `enableHeadControl`,
# `enableHeadJump`, `enableMouseJump`, `enableGazeFocus`) and set again at
# each Talon start: gaze only by default, an unsteady head drags the cursor.
# :::
#
# :::tip[Community scripts]
# Set `communityScripts` to a fetched github:talonhub/community tree to get
# full voice and gaze mouse control (zoom mouse, pop click) declaratively.
# :::
#
# :::note[Dual schemas]
# Settings go to both families: org/cinnamon/* for the UMI host session,
# org/gnome/* for GNOME sessions elsewhere. In Cinnamon, csd mirrors the
# a11y mouse keys between both families, both ways.
# Exception: keys locked by the DNF gnome module are never written here,
# a write to a locked key aborts the whole home-manager `dconf load`.
# Screen locking stays enabled GNOME-side (locked by the DNF gnome module);
# `idle-delay = 0` avoids triggering it, and the Cinnamon session has its
# own lock fully disabled.
# :::
#
# :::caution[Login keyring: autologin user only, two modes decided by the host]
# An autologin session types no password, so PAM has nothing to hand to
# gnome-keyring and every secret-using app pops a gcr prompt the UMI user
# cannot answer. A password login unlocks the keyring as usual and is left
# alone. For the autologin user, the fix depends on the host:
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
  office = config.darkone.home.office;

  # Dwell click parameters shared by the GNOME and Cinnamon a11y schemas. The
  # toggles are written even when disabled: leaving the keys out would keep a
  # previously enabled dwell click alive in the user's dconf database.
  dwellSettings = {
    dwell-click-enabled = cfg.enableDwell;
    dwell-time = cfg.dwellTime;
    dwell-threshold = 15;
    secondary-click-enabled = cfg.enableDwell;
  };

  # Talon owns Cinnamon's toggle at runtime (tracker automation): writing it
  # here would switch hover click off at every activation. GNOME's toggle too
  # on a UMI host, csd copies it onto Cinnamon's.
  umiHost = osConfig.darkone.host.umi.enable or false;
  cinnamonDwellSettings = removeAttrs dwellSettings (
    lib.optional cfg.enableTrackerAuto "dwell-click-enabled"
  );
  gnomeDwellSettings = removeAttrs dwellSettings (
    lib.optional (cfg.enableTrackerAuto && umiHost) "dwell-click-enabled"
  );

  # Optional number, boolean as Python literals
  pyNumber = value: if value == null then "None" else builtins.toJSON value;
  pyBool = value: if value then "True" else "False";

  # Talon user script: the tracker drives gaze control and hover click
  trackerScript = ''
    # DNF UMI (generated by home-manager): eye tracker plugged in -> gaze mouse
    # control and Cinnamon hover click on; unplugged -> hover click off. Gaze
    # control also follows the switch of the umi-mouse panel applet, and is
    # tuned for gaze-only pointing. Talon 0.4 and 1.0 alike.
    import os
    import subprocess
    import sys
    import threading

    import talon
    from talon import Module, actions, app, cron, registry
    from talon.track import tobii

    # Talon 1.0 moved the USB module
    try:
        from talon import usb
    except ImportError:
        from talon.lib import usb

    DCONF = "${pkgs.dconf}/bin/dconf"
    DWELL_KEY = "/org/cinnamon/desktop/a11y/mouse/dwell-click-enabled"

    # Control Mouse filter coefficients, None keeps Talon's own (1.0: 1.0, 2.0)
    GAZE_SPEED = ${pyNumber cfg.gazeFilterSpeed}
    CURSOR_SPEED = ${pyNumber cfg.cursorFilterSpeed}

    # Eye Tracking menu modes, by toggle action
    MODES = {
        "control_gaze_toggle": ${pyBool cfg.enableGazeControl},
        "control_head_toggle": ${pyBool cfg.enableHeadControl},
        "control_head_jump_toggle": ${pyBool cfg.enableHeadJump},
        "control_mouse_jump_toggle": ${pyBool cfg.enableMouseJump},
        "control_gaze_focus_toggle": ${pyBool cfg.enableGazeFocus},
    }

    # Gaze switch shared with the applet: "off" pauses gaze control, anything
    # else (or no file) keeps it on. Runtime dir: back on at every boot.
    STATE_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "dnf-umi")
    STATE_FILE = os.path.join(STATE_DIR, "gaze")

    mod = Module()
    gaze_applied = None
    tracker_seen = None
    filters_missing = False

    # Talon 1.0 runs cron jobs on several threads, without a GIL (3.14t)
    lock = threading.RLock()


    def gaze_wanted() -> bool:
        try:
            with open(STATE_FILE) as state:
                return state.read().strip() != "off"
        except OSError:
            return True


    def apply_gaze(force: bool = False) -> None:
        global gaze_applied
        with lock:
            wanted = gaze_wanted()
            if force or wanted != gaze_applied:
                gaze_applied = wanted
                actions.tracking.control_toggle(wanted)


    def set_dwell(present: bool) -> None:
        subprocess.run([DCONF, "write", DWELL_KEY, "true" if present else "false"], check=False)


    # 1.0 lists raw USB devices: the Tobii lives in the tracking system
    def tracker_present() -> bool:
        devices = getattr(getattr(talon, "tracking_system", None), "trackers", None)
        if devices is None:
            devices = usb.devices()
        return any(isinstance(dev, tobii.TobiiEC) for dev in devices)


    # Forced: control stays requested without tracker, Talon's eye mouse
    # starts on attach once requested
    def sync_tracker() -> None:
        global tracker_seen
        with lock:
            present = tracker_present()
            if present == tracker_seen:
                return
            tracker_seen = present
            if present:
                apply_gaze(force=True)
            set_dwell(present)


    # Private Control Mouse internals, no public setting: per-eye gaze filters
    # and the cursor filter. Linux Talon stops at 1.0, they will not move; 0.4
    # lacks them (logged once).
    def tune_filters() -> None:
        global filters_missing
        if GAZE_SPEED is None and CURSOR_SPEED is None:
            return
        plugin = sys.modules.get("talon.plugins.eye_mouse_2")
        mouse = getattr(plugin, "control_mouse", None)
        cursor = getattr(mouse, "target_vff", None)
        states = getattr(mouse, "states", None)
        if cursor is None or states is None:
            if not filters_missing:
                filters_missing = True
                print("DNF UMI: Control Mouse filters not found, Talon defaults kept")
            return
        if CURSOR_SPEED is not None:
            cursor.coeff = float(CURSOR_SPEED)
        if GAZE_SPEED is not None:
            for state in list(states.values()):
                gaze = getattr(state, "tobii_filter", None)
                for eye in (getattr(gaze, "left_vff", None), getattr(gaze, "right_vff", None)):
                    if eye is not None:
                        eye.coeff = float(GAZE_SPEED)


    # Any USB change; Talon's own attach handler sets the tracker up first
    def on_usb(dev) -> None:
        cron.after("1s", sync_tracker)


    def on_ready() -> None:
        apply_gaze(force=True)
        sync_tracker()

        # 1.0 "Always On" keeps the tracker streaming (lit) with control off
        if "tracking.control_always_on_toggle" in registry.actions:
            actions.tracking.control_always_on_toggle(False)

        # The applet writes the switch: a tmpfs read, no subprocess
        cron.interval("500ms", apply_gaze)

        # Declared modes win over menu choices at each Talon start; 0.4 lacks
        # some of them
        for name, on in MODES.items():
            if "tracking." + name in registry.actions:
                getattr(actions.tracking, name)(on)

        # Talon rebuilds the per-tracker state on reconnect (replug, sleep)
        tune_filters()
        cron.interval("1s", tune_filters)


    @mod.action_class
    class Actions:
        def umi_gaze(on: bool):
            """Switch DNF UMI gaze mouse control on or off (panel button state)"""
            os.makedirs(STATE_DIR, exist_ok=True)
            with open(STATE_FILE, "w") as state:
                state.write("on" if on else "off")
            apply_gaze()


    app.register("ready", on_ready)
    usb.register("attach", on_usb)
    usb.register("detach", on_usb)
  '';

  # Big cursor and text for gaze precision (~15-30 px). AT-SPI on from the
  # first login: Onboard's word prediction asks for it in a popup otherwise.
  interfaceSettings = {
    cursor-size = 48;
    text-scaling-factor = 1.25;
    toolkit-accessibility = true;
  };

  # Cinnamon caps panel symbolic icons at 50 px
  symbolicIconSize = lib.min 50 (cfg.panelHeight * 5 / 8);

  # Applet settings forced at activation, by uuid and instance id. Values must
  # sit strictly inside the schema bounds: Cinnamon resets the others when it
  # completes a partial file.
  spicesSettings = [
    {
      uuid = "menu@cinnamon.org";
      id = 0;
      values = {
        category-icon-size = 32;
        application-icon-size = 40;
        sidebar-icon-size = 32;
      };
    }
  ]
  ++ lib.optionals cfg.enablePanel [

    # Roomier entries (umi-mouse stylesheet): a larger popup keeps as many rows
    {
      uuid = "menu@cinnamon.org";
      id = 0;
      values = {
        popup-width = 760;
        popup-height = 520;
      };
    }
  ]
  ++ lib.optionals cfg.enablePanel [

    # Launchers move to their own applet, set apart from the open windows
    {
      uuid = "panel-launchers@cinnamon.org";
      id = 15;
      values = {
        launcherList = cfg.panelLaunchers;
        allow-dragging = false;
      };
    }

    # A resting gaze must not pop thumbnails up or peek at windows
    {
      uuid = "grouped-window-list@cinnamon.org";
      id = 2;
      values = {
        pinned-apps = [ ];
        onclick-thumbnails = true;
        enable-hover-peek = false;
      };
    }
  ];

  # DNF applets: hover click controls, keyboard toggle
  appletsDir = ./../../assets/cinnamon/applets;

  # Panel applets, left to right, with pinned instance ids: Cinnamon numbers
  # its stock list from 0 (existing applet settings survive), additions from 15.
  panelZones = {
    left = [
      [
        "menu@cinnamon.org"
        0
      ]
      [
        "separator@cinnamon.org"
        1
      ]
      [
        "panel-launchers@cinnamon.org"
        15
      ]
      [
        "separator@cinnamon.org"
        16
      ]
      [
        "grouped-window-list@cinnamon.org"
        2
      ]
    ];
    right = [
      [
        "umi-mouse@darkone-linux"
        17
      ]
      [
        "separator@cinnamon.org"
        18
      ]
      [
        "a11y@cinnamon.org"
        19
      ]
      [
        "umi-keyboard@darkone-linux"
        20
      ]
      [
        "separator@cinnamon.org"
        21
      ]
      [
        "systray@cinnamon.org"
        3
      ]
      [
        "xapp-status@cinnamon.org"
        4
      ]
      [
        "notifications@cinnamon.org"
        5
      ]
      [
        "printers@cinnamon.org"
        6
      ]
      [
        "removable-drives@cinnamon.org"
        7
      ]
      [
        "keyboard@cinnamon.org"
        8
      ]
      [
        "favorites@cinnamon.org"
        9
      ]
      [
        "network@cinnamon.org"
        10
      ]
      [
        "sound@cinnamon.org"
        11
      ]
      [
        "power@cinnamon.org"
        12
      ]
      [
        "calendar@cinnamon.org"
        13
      ]
      [
        "cornerbar@cinnamon.org"
        14
      ]
    ];
  };
  enabledApplets = lib.concatLists (
    lib.mapAttrsToList (
      zone:
      lib.imap0 (
        position: applet:
        "panel1:${zone}:${toString position}:${lib.elemAt applet 0}:${toString (lib.elemAt applet 1)}"
      )
    ) panelZones
  );
  nextAppletId =
    1 + lib.foldl' lib.max 0 (map (applet: lib.elemAt applet 1) (panelZones.left ++ panelZones.right));

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

  # A password login hands its password to gnome-keyring: seeding there would
  # swap an encrypted keyring for a plain one (UMI user on a non-UMI host).
  autoLogin = osConfig.services.displayManager.autoLogin;
  isAutoLoginUser = autoLogin.enable && autoLogin.user == config.home.username;
in
{
  options = {
    darkone.home.umi = {
      enable = lib.mkEnableOption "UMI multimodal input configuration (Talon + Onboard)";
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
      enableTrackerAuto = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Eye tracker plugged in: Talon gaze mouse control and hover click on;
          unplugged: hover click off (Cinnamon session). Takes over
          `enableDwell` in Cinnamon.
        '';
      };
      gazeFilterSpeed = lib.mkOption {
        type = lib.types.nullOr lib.types.numbers.positive;
        default = 2.0;
        description = ''
          Talon Control Mouse per-eye gaze filter coefficient, with
          `enableTrackerAuto`: higher reacts faster and smooths less. Talon's
          own value (1.0) freezes the cursor short of the gaze; `null` keeps it.
        '';
      };
      cursorFilterSpeed = lib.mkOption {
        type = lib.types.nullOr lib.types.numbers.positive;
        default = 4.0;
        description = ''
          Talon Control Mouse cursor filter coefficient, with
          `enableTrackerAuto`: higher reacts faster, overshoots more. `null`
          keeps Talon's own (2.0).
        '';
      };
      enableGazeControl = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Talon Gaze Control, with `enableTrackerAuto`: the cursor follows the gaze.";
      };
      enableHeadControl = lib.mkEnableOption ''
        Talon Head Control, with `enableTrackerAuto`: head movements also move
        the cursor. Off by default, an unsteady head drags the cursor away
        from the gaze'';
      enableHeadJump = lib.mkEnableOption ''
        Talon Head Jump, with `enableTrackerAuto`: a head movement brings the
        cursor to the gaze'';
      enableMouseJump = lib.mkEnableOption ''
        Talon Mouse Jump, with `enableTrackerAuto`: moving a real mouse towards
        the gaze brings the cursor there. Off by default, it yanks a helper's
        pointer'';
      enableGazeFocus = lib.mkEnableOption ''
        Talon Gaze Focus (experimental), with `enableTrackerAuto`: the window
        looked at gets the focus'';
      panelHeight = lib.mkOption {
        type = lib.types.ints.between 40 96;
        default = 64;
        description = "Cinnamon panel height in pixels, its icons follow (gaze targets).";
      };
      textScaling = lib.mkOption {
        type = lib.types.float;
        default = 1.5;
        description = "Text scaling factor of the Cinnamon session (buttons grow with their labels).";
      };
      enablePanel = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Cinnamon panel managed by DNF: launchers and open windows set apart,
          hover click controls (click types, pause zone), accessibility menu,
          keyboard toggle. Rewritten at every activation.
        '';
      };
      panelLaunchers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        # No terminal: useless without a keyboard
        default = [
          "nemo.desktop"
        ]
        ++ lib.optional (office.enable && office.enableFirefox) "firefox-esr.desktop";
        defaultText = lib.literalExpression ''[ "nemo.desktop" "firefox-esr.desktop" ]'';
        example = [
          "nemo.desktop"
          "firefox-esr.desktop"
        ];
        description = "Panel launchers (desktop file ids), with `enablePanel`.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    # Declarative Talon user scripts
    home.file.".talon/user/community" = lib.mkIf (cfg.communityScripts != null) {
      source = cfg.communityScripts;
      recursive = true;
    };
    home.file.".talon/user/dnf-umi/tracker.py" = lib.mkIf cfg.enableTrackerAuto {
      text = trackerScript;
    };

    # Cinnamon-only autostart, both installed by the UMI host: X11 clients,
    # useless under GNOME Wayland (Talon does not run, Onboard's XTest keys
    # never reach Wayland windows).
    xdg.configFile."autostart/talon.desktop" = lib.mkIf cfg.enableTalonAutostart {
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Talon
        Exec=talon
        OnlyShowIn=X-Cinnamon;
        X-GNOME-Autostart-enabled=true
      '';
    };

    # Named after Onboard's own entry to replace it: cinnamon-session starts
    # that one too (`screen-keyboard-enabled` on, for GNOME), and the second
    # instance shows the first, defeating `start-minimized`.
    xdg.configFile."autostart/onboard-autostart.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Onboard
      Exec=onboard
      OnlyShowIn=X-Cinnamon;
      X-GNOME-Autostart-enabled=true
    '';

    dconf.settings = {

      # Dwell click (both schema families, cf. header)
      "org/cinnamon/desktop/a11y/mouse" = cinnamonDwellSettings;
      "org/gnome/desktop/a11y/mouse" = gnomeDwellSettings;
      "org/cinnamon/desktop/interface" = interfaceSettings // {
        text-scaling-factor = cfg.textScaling;
      };
      "org/gnome/desktop/interface" = interfaceSettings;

      # Taller panel, icons fit to it (0 = best fit for color icons)
      "org/cinnamon" = {
        enabled-applets = lib.mkIf cfg.enablePanel enabledApplets;
        next-applet-id = lib.mkIf cfg.enablePanel nextAppletId;
        panels-height = [ "1:${toString cfg.panelHeight}" ];
        panel-zone-icon-sizes = builtins.toJSON [
          {
            panelId = 1;
            left = 0;
            center = 0;
            right = 0;
          }
        ];
        panel-zone-symbolic-icon-sizes = builtins.toJSON [
          {
            panelId = 1;
            left = symbolicIconSize;
            center = symbolicIconSize;
            right = symbolicIconSize;
          }
        ];
      };

      # Nemo: big icons, single click opens (a dwell double click needs a mode
      # switch first)
      "org/nemo/preferences".click-policy = "single";
      "org/nemo/icon-view".default-zoom-level = "large";
      "org/nemo/list-view".default-zoom-level = "large";
      "org/gnome/desktop/a11y" = {
        always-show-universal-access-status = true;
      };

      # GNOME Shell's native keyboard stands in for Onboard. Cinnamon reads
      # `org/cinnamon/desktop/a11y/applications`: no double keyboard there.
      "org/gnome/desktop/a11y/applications".screen-keyboard-enabled = true;

      # A lock screen is a dead-end without a keyboard: disable Cinnamon
      # locking entirely and never let the session go idle. The GNOME
      # `lock-enabled` key is locked host-wide by the DNF gnome module, so
      # only `idle-delay = 0` (user-overridable) protects a GNOME session.
      "org/cinnamon/desktop/screensaver" = {
        lock-enabled = false;
        idle-activation-enabled = false;
      };
      "org/cinnamon/desktop/session".idle-delay = lib.hm.gvariant.mkUint32 0;
      "org/gnome/desktop/session".idle-delay = lib.hm.gvariant.mkUint32 0;

      # Onboard tuned for touch and gaze input: fixed docked position, big
      # high-contrast targets, sticky modifiers (no key holding), word
      # prediction to cut keystrokes, jitter tolerance.
      # Hidden at login: shown on demand from its panel button or tray icon
      "org/onboard" = {
        start-minimized = true;
        show-status-icon = !cfg.enablePanel;
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

    # Cinnamon panels a UMI user cannot act on, hidden by a `NoDisplay` copy in
    # XDG_DATA_HOME: the cinnamon wrapper prepends its own `share/` to
    # XDG_DATA_DIRS, shadowing any `xdg.desktopEntries` override.
    home.file.".local/share/applications/cinnamon-settings-actions.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Actions
      Exec=cinnamon-settings actions
      NoDisplay=true
    '';
    home.file.".local/share/applications/cinnamon-settings-extensions.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=Extensions
      Exec=cinnamon-settings extensions
      NoDisplay=true
    '';

    # DNF panel layout, its applets loaded from XDG_DATA_HOME
    home.file.".local/share/cinnamon/applets/umi-mouse@darkone-linux" = lib.mkIf cfg.enablePanel {
      source = appletsDir + "/umi-mouse@darkone-linux";
    };
    home.file.".local/share/cinnamon/applets/umi-keyboard@darkone-linux" = lib.mkIf cfg.enablePanel {
      source = appletsDir + "/umi-keyboard@darkone-linux";
    };

    # Stock panel only (`enablePanel` off): its pins name `firefox.desktop`,
    # DNF ships `firefox-esr.desktop`, so the launcher is silently dropped.
    # Rewritten in place, later pins survive. The file only exists once
    # Cinnamon has run: on a fresh home, fixed at the next activation.
    home.activation.umiPanelLaunchers = lib.mkIf (!cfg.enablePanel) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        for cfgFile in "$HOME"/.config/cinnamon/spices/grouped-window-list@cinnamon.org/*.json ; do
          [ -e "$cfgFile" ] || continue
          ${pkgs.jq}/bin/jq '."pinned-apps".value |= map(
            if . == "firefox.desktop" then "firefox-esr.desktop" else . end
          )' "$cfgFile" > "$cfgFile.new" || continue
          run ${pkgs.coreutils}/bin/mv -f "$cfgFile.new" "$cfgFile"
        done
      ''
    );

    # Forced key by key: other values survive. A missing file gets the forced
    # keys only, Cinnamon completes it from the applet schema on next start
    # (no file monitor: changes apply at the next login).
    home.activation.umiCinnamonSpices = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      spicesSet() {
        cfgDir="$HOME/.config/cinnamon/spices/$1"
        cfgFile="$cfgDir/$2.json"
        run ${pkgs.coreutils}/bin/mkdir -p "$cfgDir"
        if [ -e "$cfgFile" ] ; then
          ${pkgs.jq}/bin/jq --argjson v "$3" \
            'reduce ($v | to_entries[]) as $e (.; .[$e.key].value = $e.value)' \
            "$cfgFile" > "$cfgFile.new" || return 0
        else
          ${pkgs.jq}/bin/jq -n --argjson v "$3" '$v | map_values({ value: . })' \
            > "$cfgFile.new" || return 0
        fi
        run ${pkgs.coreutils}/bin/mv -f "$cfgFile.new" "$cfgFile"
      }
      ${lib.concatMapStrings (
        s: "spicesSet ${s.uuid} ${toString s.id} ${lib.escapeShellArg (builtins.toJSON s.values)}\n"
      ) spicesSettings}
    '';

    # Passwordless login keyring, for the autologin user of an unencrypted host
    # only (cf. the header): gnome-keyring tries an empty password before
    # prompting, and stores such a keyring as plain ini, not an encrypted blob.
    home.activation.umiLoginKeyring = lib.mkIf (isAutoLoginUser && !hostHasLuks) (
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
