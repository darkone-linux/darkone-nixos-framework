// UMI hover click controls in the panel: click-type buttons and a pause zone.
//
// - Click type: `org.cinnamon hoverclick-action`, as Cinnamon's floating
//   window does; that window stays closed while this applet is loaded.
// - Single click once: one left click, then hover click pauses as from the
//   pause zone; resuming brings the repeated single click back.
// - Pause zone: a click switches hover click off (`dwell-click-enabled`);
//   resting the pointer on it for RESUME_MS, or a click, switches it back on.
// - Gaze button: switches Talon's gaze mouse control off, the eyes then move
//   nothing; back on with the mouse, touch or voice (`user.umi_gaze`). Hover
//   click is paused with it (mouse in hand), resumed when gaze comes back.
// - Hidden while hover click is off, unless paused from here; click types
//   hidden during the pause, back on resume.

const Applet = imports.ui.applet;
const Clutter = imports.gi.Clutter;
const Gio = imports.gi.Gio;
const GLib = imports.gi.GLib;
const Dialogs = imports.ui.wmGtkDialogs;
const Main = imports.ui.main;
const St = imports.gi.St;

// Rest time on the zone to resume, gaze jitter tolerated outside it
const RESUME_MS = 1500;
const LEAVE_GRACE_MS = 400;

// The second click of a dwell double click lands right after the first
const DEBOUNCE_MS = 1000;

// "once": a single click, applet-side, not a `hoverclick-action` value
const CLICK_TYPES = ["single", "once", "double", "drag", "secondary"];

// Gaze switch shared with the Talon user script (dnf-umi/tracker.py): "off"
// pauses gaze control. Runtime dir: back on at every boot.
const GAZE_DIR = GLib.build_filenamev([GLib.get_user_runtime_dir(), "dnf-umi"]);
const GAZE_FILE = GLib.build_filenamev([GAZE_DIR, "gaze"]);

class UmiMouseApplet extends Applet.Applet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);

        this._iconDir = `${metadata.path}/icons`;
        this._mouse = new Gio.Settings({ schema_id: "org.cinnamon.desktop.a11y.mouse" });
        this._paused = false;
        this._once = false;
        this._onceId = 0;
        this._armed = true;
        this._resuming = false;
        this._lastChange = 0;
        this._graceId = 0;

        this._buttons = new Map();
        for (const type of CLICK_TYPES) {
            const button = this._iconButton(`click-${type}.svg`);
            this._bindActivation(button, () => this._setClickType(type));
            this._buttons.set(type, button);
            this.actor.add_child(button);
        }

        this._fill = new St.Widget({
            style_class: "umi-zone-fill",
            x_align: Clutter.ActorAlign.START,
            y_expand: true,
            width: 0,
        });
        this._zoneIcon = new St.Icon({
            icon_type: St.IconType.SYMBOLIC,
            x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER,
            x_expand: true,
        });
        this._zone = new St.Widget({
            style_class: "umi-zone",
            layout_manager: new Clutter.BinLayout(),
            reactive: true,
            track_hover: true,
        });
        this._zone.add_child(this._fill);
        this._zone.add_child(this._zoneIcon);
        this._zone.connect("notify::hover", () => this._onZoneHover());
        this._bindActivation(this._zone, () => this._onZoneActivated());
        this.actor.add_child(this._zone);

        this._lastGazeToggle = 0;
        this._gazeState = null;
        this._gazeButton = this._iconButton("gaze-on.svg");
        this._bindActivation(this._gazeButton, () => this._toggleGaze());
        this.actor.add_child(this._gazeButton);
        GLib.mkdir_with_parents(GAZE_DIR, 0o700);
        this._gazeMonitor = Gio.File.new_for_path(GAZE_FILE).monitor_file(Gio.FileMonitorFlags.NONE, null);

        const seat = Clutter.get_default_backend().get_default_seat();
        this._signals = [
            [global.settings, global.settings.connect("changed::hoverclick-action", () => this._sync())],
            [this._mouse, this._mouse.connect("changed::dwell-click-enabled", () => this._onDwellChanged())],
            [this._gazeMonitor, this._gazeMonitor.connect("changed", () => this._syncGaze())],
            [seat, seat.connect("ptr-a11y-timeout-stopped", (_seat, _device, type, clicked) =>
                this._onDwellStopped(type, clicked))],
        ];
        this._holdFloatingWindow(true);
        this._sync();
        this._syncGaze();
    }

    on_applet_added_to_panel() {
        this._resize(this.getPanelIconSize(St.IconType.FULLCOLOR));
    }

    on_panel_icon_size_changed(size) {
        this._resize(size);
    }

    on_applet_removed_from_panel() {
        this._cancelResume();
        if (this._onceId)
            GLib.source_remove(this._onceId);
        for (const [object, id] of this._signals)
            object.disconnect(id);
        this._gazeMonitor.cancel();
        this._holdFloatingWindow(false);
    }

    _resize(size) {
        if (!size)
            return;
        for (const button of [...this._buttons.values(), this._gazeButton])
            button.child.icon_size = size;
        this._zoneIcon.icon_size = Math.round(size * 0.75);
        this._zone.width = size * 2;
    }

    _iconButton(file) {
        const icon = new St.Icon({ gicon: Gio.FileIcon.new(Gio.File.new_for_path(`${this._iconDir}/${file}`)) });
        return new St.Bin({ style_class: "umi-button", reactive: true, track_hover: true, child: icon });
    }

    // Press swallowed (no applet context menu on a dwell secondary click),
    // action on release: a dwell drag ends with it, no button left pressed.
    _bindActivation(actor, callback) {
        actor.connect("button-press-event", () => Clutter.EVENT_STOP);
        actor.connect("button-release-event", () => {
            callback();
            return Clutter.EVENT_STOP;
        });
        actor.connect("touch-event", (_actor, event) => {
            if (event.type() === Clutter.EventType.TOUCH_END)
                callback();
            return Clutter.EVENT_STOP;
        });
    }

    // Cinnamon's floating click-type window duplicates the buttons. Patched on
    // the prototype: applets load before Main.a11yHandler exists. Private API,
    // on failure the window simply shows up again.
    _holdFloatingWindow(hold) {
        try {
            const proto = Dialogs.HoverClickHelper.prototype;
            if (hold) {
                this._setActive = proto.set_active;
                proto.set_active = function (active) {
                    if (!active)
                        this.close();
                };
                Main.a11yHandler?._hoverclick_helper.close();
            } else if (this._setActive) {
                proto.set_active = this._setActive;
            }
        } catch (e) {
            global.logWarning(`umi-mouse: floating click-type window not managed: ${e}`);
        }
    }

    _setClickType(type) {
        if (this._paused)
            return;
        this._once = type === "once";
        global.settings.set_string("hoverclick-action", this._once ? "single" : type);
        this._sync();
    }

    // Emitted before the click itself: the dwell that selected "once" has
    // already stopped, the next completed one is the single click. Pause on
    // idle, once the click is out.
    _onDwellStopped(type, clicked) {
        if (!this._once || !clicked || type !== Clutter.PointerA11yTimeoutType.DWELL || this._onceId)
            return;
        this._onceId = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            this._onceId = 0;
            if (this._once && !this._paused)
                this._pause();
            return GLib.SOURCE_REMOVE;
        });
    }

    _onZoneActivated() {
        if (!this._armed || Date.now() - this._lastChange < DEBOUNCE_MS)
            return;
        if (this._paused)
            this._resume();
        else
            this._pause();
    }

    _pause() {
        this._paused = true;
        this._lastChange = Date.now();
        this._mouse.set_boolean("dwell-click-enabled", false);
        this._sync();
    }

    // Back to a single click; disarmed until the pointer leaves the zone, or
    // the next dwell would pause again at once.
    _resume() {
        this._cancelResume();
        this._paused = false;
        this._armed = !this._zone.hover;
        this._lastChange = Date.now();
        global.settings.set_string("hoverclick-action", "single");
        this._mouse.set_boolean("dwell-click-enabled", true);
        this._sync();
    }

    // Any outside switch-on ends the pause; a switch-off while paused keeps it.
    // Any switch-off ends "once": a resume is back to repeated clicks.
    _onDwellChanged() {
        if (this._mouse.get_boolean("dwell-click-enabled"))
            this._paused = false;
        else
            this._once = false;
        this._sync();
    }

    _onZoneHover() {
        if (this._zone.hover) {
            this._clearGrace();
            if (this._paused && !this._resuming)
                this._startResume();
            return;
        }
        this._armed = true;
        if (this._resuming && !this._graceId) {
            this._graceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, LEAVE_GRACE_MS, () => {
                this._graceId = 0;
                this._cancelResume();
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    // The fill bar is the timer: only a completed transition resumes
    _startResume() {
        this._resuming = true;
        this._fill.width = 0;
        this._fill.ease({
            width: this._zone.width,
            duration: RESUME_MS,
            mode: Clutter.AnimationMode.LINEAR,
            onComplete: () => this._resume(),
        });
    }

    _cancelResume() {
        this._clearGrace();
        this._resuming = false;
        this._fill.remove_all_transitions();
        this._fill.width = 0;
    }

    _clearGrace() {
        if (this._graceId) {
            GLib.source_remove(this._graceId);
            this._graceId = 0;
        }
    }

    _gazeOn() {
        try {
            const [, contents] = GLib.file_get_contents(GAZE_FILE);
            return new TextDecoder().decode(contents).trim() !== "off";
        } catch (e) {
            return true;
        }
    }

    _toggleGaze() {
        if (Date.now() - this._lastGazeToggle < DEBOUNCE_MS)
            return;
        this._lastGazeToggle = Date.now();
        GLib.mkdir_with_parents(GAZE_DIR, 0o700);
        GLib.file_set_contents(GAZE_FILE, this._gazeOn() ? "off" : "on");
        this._syncGaze();
    }

    // Any source of change (button, voice action): the file monitor reports
    // them all, the applet's own writes included.
    _syncGaze() {
        const on = this._gazeOn();
        if (on !== this._gazeState) {
            this._gazeState = on;
            if (!on && this._mouse.get_boolean("dwell-click-enabled"))
                this._pause();
            else if (on && this._paused)
                this._resume();
        }
        this._gazeButton.child.gicon = Gio.FileIcon.new(
            Gio.File.new_for_path(`${this._iconDir}/gaze-${on ? "on" : "off"}.svg`)
        );
        if (on)
            this._gazeButton.remove_style_class_name("umi-gaze-off");
        else
            this._gazeButton.add_style_class_name("umi-gaze-off");
    }

    _sync() {
        const enabled = this._mouse.get_boolean("dwell-click-enabled");
        let current = global.settings.get_string("hoverclick-action");

        // A type chosen elsewhere (voice, settings) ends "once"
        if (this._once && current !== "single")
            this._once = false;
        if (this._once)
            current = "once";

        this.actor.visible = enabled || this._paused;
        if (!this._paused)
            this._cancelResume();

        // Right-aligned panel zone: the pause zone stays put under the pointer
        for (const [type, button] of this._buttons) {
            button.visible = !this._paused;
            if (type === current)
                button.add_style_class_name("umi-selected");
            else
                button.remove_style_class_name("umi-selected");
        }

        this._zoneIcon.icon_name = this._paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic";
        if (this._paused)
            this._zone.add_style_class_name("umi-zone-paused");
        else
            this._zone.remove_style_class_name("umi-zone-paused");
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new UmiMouseApplet(metadata, orientation, panelHeight, instanceId);
}
