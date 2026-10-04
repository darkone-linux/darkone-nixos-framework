// UMI on-screen keyboard button: shows or hides Onboard over D-Bus, starts it
// when absent. Onboard's own tray icon is off, so the panel order stays fixed.

const Applet = imports.ui.applet;
const Clutter = imports.gi.Clutter;
const Gio = imports.gi.Gio;
const St = imports.gi.St;
const Util = imports.misc.util;

// The second click of a dwell double click would toggle straight back
const DEBOUNCE_MS = 1000;

class UmiKeyboardApplet extends Applet.Applet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);

        this._lastToggle = 0;
        this._icon = new St.Icon({
            gicon: new Gio.ThemedIcon({ names: ["onboard", "input-keyboard"] }),
            icon_type: St.IconType.FULLCOLOR,
        });
        this._button = new St.Bin({ style_class: "umi-button", reactive: true, track_hover: true, child: this._icon });

        // Press swallowed: no applet context menu on a dwell secondary click
        this._button.connect("button-press-event", () => Clutter.EVENT_STOP);
        this._button.connect("button-release-event", () => {
            this._toggle();
            return Clutter.EVENT_STOP;
        });
        this._button.connect("touch-event", (_actor, event) => {
            if (event.type() === Clutter.EventType.TOUCH_END)
                this._toggle();
            return Clutter.EVENT_STOP;
        });
        this.actor.add_child(this._button);
    }

    on_applet_added_to_panel() {
        this.on_panel_icon_size_changed(this.getPanelIconSize(St.IconType.FULLCOLOR));
    }

    on_panel_icon_size_changed(size) {
        if (size)
            this._icon.icon_size = size;
    }

    _toggle() {
        if (Date.now() - this._lastToggle < DEBOUNCE_MS)
            return;
        this._lastToggle = Date.now();

        Gio.DBus.session.call(
            "org.onboard.Onboard",
            "/org/onboard/Onboard/Keyboard",
            "org.onboard.Onboard.Keyboard",
            "ToggleVisible",
            null,
            null,
            Gio.DBusCallFlags.NO_AUTO_START,
            -1,
            null,
            (connection, result) => {
                try {
                    connection.call_finish(result);
                } catch (e) {
                    Util.spawn(["onboard"]);
                }
            }
        );
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new UmiKeyboardApplet(metadata, orientation, panelHeight, instanceId);
}
