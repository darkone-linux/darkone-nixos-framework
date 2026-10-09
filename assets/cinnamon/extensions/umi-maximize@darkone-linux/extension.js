// UMI maximized windows: every application window opens maximized, a large
// gaze target with the panel still in reach (fullscreen would hide it).

const Meta = imports.gi.Meta;

let createdId = 0;

// Requested before placement: muffin maximizes while placing, the window maps
// maximized without a visible resize. Dialogs, Onboard (dock), windows out
// of the taskbar and fixed-size windows keep their own geometry.
function onWindowCreated(_display, window) {
    if (window.get_window_type() !== Meta.WindowType.NORMAL
        || window.is_skip_taskbar()
        || window.get_transient_for() !== null
        || !window.can_maximize())
        return;
    window.maximize(Meta.MaximizeFlags.BOTH);
}

function init(_metadata) {}

function enable() {
    createdId = global.display.connect("window-created", onWindowCreated);
}

function disable() {
    if (createdId) {
        global.display.disconnect(createdId);
        createdId = 0;
    }
}
