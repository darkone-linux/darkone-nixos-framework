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
#   `umi-mouse`), accessibility menu, Onboard toggle. Menu favorites
#   (`menuFavorites`) open with the eye tracker calibration. Application
#   windows open maximized, panel in reach (`enableMaximize`).
# - **Any other host**: GNOME Wayland with its native accessibility: on-screen
#   keyboard, big pointer and text. Talon and Onboard, X11-only, stay off.
#
# Dwell click: opt-in (`enableDwell`) under GNOME. In Cinnamon, a Talon user
# script makes it follow the eye tracker, with gaze control (`enableTrackerAuto`).
# Talon 0.4 and 1.0 alike; 1.0's "Always On" is switched off, the tracker goes
# dark with gaze control.
# :::
#
# :::note[Application grid (UMI host)]
# `enableRofiMenu`: the first panel launcher opens a full-screen rofi grid,
# pages of `rofiGridResolution` tiles turned by edge-high buttons, one click
# launches, settings panels left out. `hiddenApps` hides entries from the grid
# and the Cinnamon menu alike. rofi grabs the pointer: panel out of reach.
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
# :::tip[Gaze places, head refines]
# With `enableHeadControl`, `headSpeed` below 1 dampens ample head movements
# (`head_bezier.vmax` scaled, lever to be validated on a Tobii 5). Live tuning
# from Talon's REPL, lost on restart: `actions.user.umi_head_speed(0.3)`,
# `actions.user.umi_filter_speed(2, 4)`, `print(actions.user.umi_tuning())`.
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
# :::caution[Login keyring of the autologin user: no password, on every host]
# An autologin session types no password: a keyring sealed with one pops a gcr
# prompt the UMI user cannot answer. Its login keyring is seeded with an empty
# password (plain ini, unlocked without prompt); a sealed one is deleted at
# each activation, `user.keystore` included, and its secrets are lost.
#
# - At rest, LUKS protects it; autologin already hands the session to whoever
#   boots the machine.
# - The UMI host keeps every password away from gnome-keyring for this user:
#   a plain keyring unlocked with a password is re-encrypted with it at the
#   next write (`pam_gdm` and the boot passphrase included).
# - Other users, and every password login elsewhere: untouched.
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
    # tuned for gaze-only pointing; a menu entry starts the calibration.
    # Talon 0.4 and 1.0 alike.
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

    # Head Control sensitivity, None keeps Talon's own: below 1, full cursor
    # gain needs a faster head. All three speeds: REPL actions override them.
    HEAD_SPEED = ${pyNumber cfg.headSpeed}

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

    # One-shot calibration request, written by the `dnf-umi-calibrate` menu entry
    CALIBRATE_FILE = os.path.join(STATE_DIR, "calibrate")

    mod = Module()
    gaze_applied = None
    tracker_seen = None
    filters_missing = False
    head_missing = False

    # Talon's own head curve span, captured before the first change
    head_vmax = None

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


    # Consumes the request: an atomic removal, one calibration per click even
    # across cron threads
    def calibrate_requested() -> bool:
        try:
            os.remove(CALIBRATE_FILE)
        except OSError:
            return False
        return True


    def poll_calibrate() -> None:
        if calibrate_requested():
            actions.tracking.calibrate()


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


    def control_mouse():
        plugin = sys.modules.get("talon.plugins.eye_mouse_2")
        return getattr(plugin, "control_mouse", None)


    # Scaled from Talon's own span, never from the last value: no compounding
    # at each pass, a speed of 1 restores Talon's curve
    def tune_head(mouse) -> None:
        global head_vmax, head_missing
        if HEAD_SPEED is None and head_vmax is None:
            return
        curve = getattr(mouse, "head_bezier", None)
        try:
            if head_vmax is None:
                head_vmax = float(curve.vmax)
            curve.vmax = head_vmax / (HEAD_SPEED or 1.0)
        except (AttributeError, TypeError):
            if not head_missing:
                head_missing = True
                print("DNF UMI: Control Mouse head curve not found, Talon default kept")


    # Private Control Mouse internals, no public setting: per-eye gaze filters,
    # cursor filter, head curve. Linux Talon stops at 1.0, they will not move;
    # 0.4 lacks them (logged once).
    def tune_filters() -> None:
        global filters_missing
        with lock:
            mouse = control_mouse()
            tune_head(mouse)
            if GAZE_SPEED is None and CURSOR_SPEED is None:
                return
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


    # Fields of a Talon object, cut: some hold whole histories
    def show(value) -> str:
        text = repr(getattr(value, "__dict__", None) or value)
        return text if len(text) <= 300 else text[:300] + "..."


    # Every head-related member is listed: the curve is a guess, the others
    # are the next levers to try
    def tuning_report() -> str:
        lines = [
            f"DNF speeds: gaze={GAZE_SPEED} cursor={CURSOR_SPEED} head={HEAD_SPEED}",
            f"Talon head vmax: {head_vmax}",
        ]
        mouse = control_mouse()
        if mouse is None:
            return "\n".join(lines + ["Control Mouse not found"])
        lines.append(f"target_vff: {show(getattr(mouse, 'target_vff', None))}")
        for state in list((getattr(mouse, "states", None) or {}).values()):
            gaze = getattr(state, "tobii_filter", None)
            for side in ("left_vff", "right_vff"):
                lines.append(f"tobii_filter.{side}: {show(getattr(gaze, side, None))}")
        for name in dir(mouse):
            if "head" in name and not name.startswith("__"):
                lines.append(f"{name}: {show(getattr(mouse, name, None))}")
        last = getattr(mouse, "last_state", None)
        lines.append(
            f"last_state: head_active={getattr(last, 'head_active', None)}"
            f" offset_mm={getattr(last, 'offset_mm', None)}"
        )
        return "\n".join(lines)


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

        # A request left while Talon was down would start a surprise calibration
        calibrate_requested()
        cron.interval("500ms", poll_calibrate)

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

        def umi_filter_speed(gaze: float, cursor: float):
            """Set DNF UMI gaze and cursor filter speeds until Talon restarts (Talon's own: 1, 2)"""
            global GAZE_SPEED, CURSOR_SPEED
            if gaze <= 0 or cursor <= 0:
                raise ValueError("speeds must be positive")
            GAZE_SPEED, CURSOR_SPEED = float(gaze), float(cursor)
            tune_filters()

        def umi_head_speed(speed: float):
            """Set DNF UMI head control sensitivity until Talon restarts (Talon's own: 1)"""
            global HEAD_SPEED
            if speed <= 0:
                raise ValueError("speed must be positive")
            HEAD_SPEED = float(speed)
            tune_filters()

        def umi_tuning() -> str:
            """DNF UMI eye tracking tuning: applied speeds and Talon's internal values"""
            return tuning_report()


    app.register("ready", on_ready)
    usb.register("attach", on_usb)
    usb.register("detach", on_usb)
  '';

  # Calibration request for the Talon user script, polled every 500 ms
  calibrateRequest = pkgs.writeShellScript "dnf-umi-calibrate" ''
    dir="''${XDG_RUNTIME_DIR:-/tmp}/dnf-umi"
    ${pkgs.coreutils}/bin/mkdir -p -m 700 "$dir"
    : > "$dir/calibrate"
  '';

  # Application grid: rofi is X11-only here (GNOME Wayland lacks layer shell)
  rofiMenu = cfg.enableRofiMenu && umiHost;
  gridLauncher = "dnf-umi-grid.desktop";

  # The theme has no translation mechanism: its one label follows the host locale
  closeLabel = if lib.hasPrefix "fr" osConfig.i18n.defaultLocale then "Fermer" else "Close";

  # Tuned on a 1600×900 screen: 96 px icons, `@theme` drops rofi's default
  # theme, so every drawn property is set here.
  rofiTheme =
    let
      inherit (config.lib.formats.rasi) mkLiteral;
      px = n: mkLiteral "${toString n}px";
      centered = mkLiteral "0.5";
    in
    {
      "*" = {
        font = "Sans 15";
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "#eeeeee";
      };
      window = {
        fullscreen = true;
        background-color = mkLiteral "rgba(18, 18, 24, 0.94)";
        padding = px 24;
      };
      mainbox = {
        orientation = mkLiteral "horizontal";
        spacing = px 16;

        # Quoted names: a bare one may parse as a keyword (`center`, a position)
        children = [
          "button-prev"
          "grid"
          "button-next"
        ];
      };

      # Edge-high page buttons, the widest gaze targets of the grid
      "button-prev, button-next" = {
        expand = false;
        width = px 150;
        font = "Sans Bold 64";
        horizontal-align = centered;
        vertical-align = centered;
        border-radius = px 24;
        background-color = mkLiteral "rgba(255, 255, 255, 0.07)";
      };
      button-prev = {
        content = "◀";
        action = "kb-page-prev";
      };
      button-next = {
        content = "▶";
        action = "kb-page-next";
      };
      grid = {
        orientation = mkLiteral "vertical";
        spacing = px 16;
        children = [
          "topbar"
          "listview"
        ];
      };
      topbar = {
        orientation = mkLiteral "horizontal";
        expand = false;
        children = [ "button-close" ];
      };
      button-close = {
        content = "✕  ${closeLabel}";
        action = "kb-cancel";
        expand = false;
        padding = mkLiteral "18px 36px";
        border-radius = px 16;
        background-color = mkLiteral "rgba(255, 90, 90, 0.30)";
      };
      listview = {
        columns = cfg.rofiGridResolution.columns;
        lines = cfg.rofiGridResolution.rows;
        fixed-height = true;
        fixed-columns = true;
        scrollbar = false;
        cycle = false;
        flow = mkLiteral "horizontal";
        spacing = px 16;
        border = 0;
      };
      element = {
        orientation = mkLiteral "vertical";
        padding = px 14;
        spacing = px 8;
        border-radius = px 20;
      };
      "element normal.normal, element alternate.normal" = {
        background-color = mkLiteral "rgba(255, 255, 255, 0.05)";
        text-color = mkLiteral "#eeeeee";
      };
      "element selected.normal" = {
        background-color = mkLiteral "rgba(79, 195, 247, 0.40)";
        text-color = mkLiteral "#ffffff";
      };
      "element-text, element-icon" = {
        background-color = mkLiteral "transparent";
        text-color = mkLiteral "inherit";
      };
      element-icon = {
        size = px 96;
        horizontal-align = centered;
      };
      element-text = {
        horizontal-align = centered;
        vertical-align = centered;
      };
    };

  # Full copies with `NoDisplay` forced: a bare stub would also shadow the
  # entry for launches by id and file associations. Leading blanks allowed,
  # as GKeyFile does: talon-nix indents its whole entry.
  hiddenAppEntries = pkgs.runCommand "umi-hidden-apps" { } ''
    mkdir -p $out
    for id in ${lib.escapeShellArgs cfg.hiddenApps} ; do
      for dir in ${osConfig.system.path}/share/applications ${config.home.path}/share/applications ; do
        if [ -e "$dir/$id" ] ; then
          sed -e '/^[[:blank:]]*NoDisplay=/d' -e '/^[[:blank:]]*\[Desktop Entry\]/a NoDisplay=true' "$dir/$id" > "$out/$id"
          break
        fi
      done
    done
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

    # Launchers move to their own applet, set apart from the open windows; the
    # application grid comes first
    {
      uuid = "panel-launchers@cinnamon.org";
      id = 15;
      values = {
        launcherList = lib.optional rofiMenu gridLauncher ++ cfg.panelLaunchers;
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

  # DNF extension: application windows open maximized
  maximizeExtension = "umi-maximize@darkone-linux";

  # Panel applets, left to right, with pinned instance ids: Cinnamon numbers
  # its stock list from 0 (existing applet settings survive), additions from 15.
  applet = uuid: id: { inherit uuid id; };
  panelZones = {
    left = [
      (applet "menu@cinnamon.org" 0)
      (applet "separator@cinnamon.org" 1)
      (applet "panel-launchers@cinnamon.org" 15)
      (applet "separator@cinnamon.org" 16)
      (applet "grouped-window-list@cinnamon.org" 2)
    ];
    right = [
      (applet "umi-mouse@darkone-linux" 17)
      (applet "separator@cinnamon.org" 18)
      (applet "a11y@cinnamon.org" 19)
      (applet "umi-keyboard@darkone-linux" 20)
      (applet "separator@cinnamon.org" 21)
      (applet "systray@cinnamon.org" 3)
      (applet "xapp-status@cinnamon.org" 4)
      (applet "notifications@cinnamon.org" 5)
      (applet "printers@cinnamon.org" 6)
      (applet "removable-drives@cinnamon.org" 7)
      (applet "keyboard@cinnamon.org" 8)
      (applet "favorites@cinnamon.org" 9)
      (applet "network@cinnamon.org" 10)
      (applet "sound@cinnamon.org" 11)
      (applet "power@cinnamon.org" 12)
      (applet "calendar@cinnamon.org" 13)
    ];
  };
  enabledApplets = lib.concatLists (
    lib.mapAttrsToList (
      zone: lib.imap0 (position: a: "panel1:${zone}:${toString position}:${a.uuid}:${toString a.id}")
    ) panelZones
  );
  nextAppletId = 1 + lib.foldl' lib.max 0 (map (a: a.id) (panelZones.left ++ panelZones.right));

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
      headSpeed = lib.mkOption {
        type = lib.types.nullOr lib.types.numbers.positive;
        default = null;
        example = 0.3;
        description = ''
          Talon Head Control sensitivity, with `enableTrackerAuto` and
          `enableHeadControl`: below 1 the head moves the cursor less (ample,
          poorly controlled movements). `null` keeps Talon's own (1).
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
          keyboard toggle; no Bluetooth icon nor corner bar. Rewritten at
          every activation.
        '';
      };
      enableMaximize = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Application windows open maximized (Cinnamon extension), the panel
          stays in reach. Dialogs, Onboard and fixed-size windows keep their
          size.
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
      menuFavorites = lib.mkOption {
        type = lib.types.listOf lib.types.str;

        # Cinnamon's stock list, minus apps absent here (xed, mintinstall)
        default = lib.optional cfg.enableTrackerAuto "dnf-umi-calibrate.desktop" ++ [
          "org.gnome.Calculator.desktop"
          "org.gnome.Calendar.desktop"
          "cinnamon-settings.desktop"
        ];
        defaultText = lib.literalExpression ''
          [
            "dnf-umi-calibrate.desktop"
            "org.gnome.Calculator.desktop"
            "org.gnome.Calendar.desktop"
            "cinnamon-settings.desktop"
          ]
        '';
        description = ''
          Cinnamon menu favorites (desktop file ids), rewritten at every
          activation. `dnf-umi-calibrate.desktop`, with `enableTrackerAuto`,
          starts the eye tracker calibration.
        '';
      };
      enableRofiMenu = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Full-screen application grid (rofi), UMI host only: pages of big
          tiles turned by edge buttons, one click launches, settings panels
          left out. Opened by the first panel launcher (with `enablePanel`).
        '';
      };
      rofiGridResolution = lib.mkOption {
        type = lib.types.submodule {
          options = {
            columns = lib.mkOption {
              type = lib.types.ints.between 1 12;
              default = 6;
              description = "Tiles per row.";
            };
            rows = lib.mkOption {
              type = lib.types.ints.between 1 8;
              default = 4;
              description = "Tile rows per page.";
            };
          };
        };
        default = { };
        example = {
          columns = 4;
          rows = 3;
        };
        description = ''
          Application grid page, in tiles, with `enableRofiMenu`. The default
          6 × 4 fits 96 px icons on a 1600×900 screen; fewer tiles grow wider.
        '';
      };
      hiddenApps = lib.mkOption {
        type = lib.types.listOf lib.types.str;

        # Terminals (no keyboard), duplicates of Nemo and Onboard, admin manual
        default = [
          "xterm.desktop"
          "org.gnome.Terminal.desktop"
          "org.gnome.Console.desktop"
          "org.gnome.Nautilus.desktop"
          "cinnamon-onscreen-keyboard.desktop"
          "nixos-manual.desktop"
        ];
        description = ''
          Applications hidden from the grid and the Cinnamon menu (desktop file
          ids), UMI host only. Launches by id and file associations still work.
        '';
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

    # Talon's own Calibrate item sits in its tray menu, out of a gaze user's
    # reach: a menu favorite asks the tracker script for it (Cinnamon only).
    xdg.desktopEntries.dnf-umi-calibrate = lib.mkIf cfg.enableTrackerAuto {
      name = "Eye Tracker Calibration";
      comment = "Calibrate the eye tracker (Talon)";
      exec = "${calibrateRequest}";
      icon = ./../../assets/cinnamon/icons/umi-calibrate.svg;
      categories = [
        "Utility"
        "Accessibility"
      ];
      settings = {
        "Name[fr]" = "Calibrer le regard";
        "Comment[fr]" = "Calibrer l'eye tracker (Talon)";
        OnlyShowIn = "X-Cinnamon;";
      };
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

    # Bluetooth icon of blueman-applet (nixpkgs Cinnamon default) left out of
    # the DNF panel: `Hidden=true` masks the system autostart entry for this
    # user. Pairing stays in the menu, Bluetooth Manager.
    xdg.configFile."autostart/blueman.desktop" = lib.mkIf cfg.enablePanel {
      text = ''
        [Desktop Entry]
        Type=Application
        Name=Blueman Applet
        Hidden=true
      '';
    };

    dconf.settings = {

      # Dwell click (both schema families, cf. header)
      "org/cinnamon/desktop/a11y/mouse" = cinnamonDwellSettings;
      "org/gnome/desktop/a11y/mouse" = gnomeDwellSettings;
      "org/cinnamon/desktop/interface" = interfaceSettings // {
        text-scaling-factor = cfg.textScaling;
      };
      "org/gnome/desktop/interface" = interfaceSettings;

      # Menu favorites; taller panel, icons fit to it (0 = best fit for color icons)
      "org/cinnamon" = {
        favorite-apps = cfg.menuFavorites;

        # Always written: a left-out key keeps a disabled extension enabled
        enabled-extensions = lib.optional cfg.enableMaximize maximizeExtension;
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

    # Hidden entries (cf. `hiddenAppEntries`), UMI host only: GNOME elsewhere
    # would lose them too, Nautilus being its only file manager.
    home.file.".local/share/applications" = lib.mkIf (umiHost && cfg.hiddenApps != [ ]) {
      source = hiddenAppEntries;
      recursive = true;
    };

    # Application grid, its config read by any `rofi -show drun`
    programs.rofi = lib.mkIf rofiMenu {
      enable = true;
      theme = rofiTheme;
      settings = {
        modes = "drun";
        show-icons = true;
        drun-display-format = "{name}";

        # Installed by the desktop profile, the fullest colour app icon set
        icon-theme = "Papirus";

        # Settings panels stay in the Cinnamon menu, out of the gaze grid
        drun-exclude-categories = "Settings";

        # Whole pages, never a scrolled row
        scroll-method = 0;

        # Hover selects, one primary click (a dwell click) launches
        hover-select = true;
        me-select-entry = "";
        me-accept-entry = "MousePrimary";

        # A stray dwell beside the grid must not close it
        click-to-exit = false;
      };
    };

    # Grid button, in Cinnamon's custom launcher folder: a launcher with no
    # entry of its own in the menu or the grid.
    home.file.".local/share/cinnamon/panel-launchers/${gridLauncher}" =
      lib.mkIf (rofiMenu && cfg.enablePanel)
        {
          text = ''
            [Desktop Entry]
            Type=Application
            Name=Applications
            Comment=All applications, in pages of big tiles
            Comment[fr]=Toutes les applications, en pages de grandes tuiles
            Exec=${config.programs.rofi.finalPackage}/bin/rofi -show drun
            Icon=app-launcher
          '';
        };

    # DNF panel layout, its applets loaded from XDG_DATA_HOME
    home.file.".local/share/cinnamon/applets/umi-mouse@darkone-linux" = lib.mkIf cfg.enablePanel {
      source = appletsDir + "/umi-mouse@darkone-linux";
    };
    home.file.".local/share/cinnamon/applets/umi-keyboard@darkone-linux" = lib.mkIf cfg.enablePanel {
      source = appletsDir + "/umi-keyboard@darkone-linux";
    };

    # Maximized windows, enabled through `enabled-extensions` (dconf above)
    home.file.".local/share/cinnamon/extensions/${maximizeExtension}" = lib.mkIf cfg.enableMaximize {
      source = ./../../assets/cinnamon/extensions + "/${maximizeExtension}";
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

    # Passwordless login keyring, for the autologin user only (cf. the header):
    # gnome-keyring tries an empty password before prompting, and stores such a
    # keyring as plain ini, not an encrypted blob.
    home.activation.umiLoginKeyring = lib.mkIf isAutoLoginUser (
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
