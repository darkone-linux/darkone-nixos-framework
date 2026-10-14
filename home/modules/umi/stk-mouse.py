"""Run SuperTuxKart driven by a mouse alone (DNF UMI `enableStkWithMouse`).

Usage: dnf-stk-mouse GAME [ARGS...]

While the game window holds the focus, mouse moves and clicks hold the
game's default keys through a virtual keyboard. The pointer keeps working
(menus), the game ignores it in race. Doc: `../umi.nix` header.
"""

import collections
import os
import selectors
import subprocess
import sys
import time

import evdev
import Xlib.display
import Xlib.error
from evdev import ecodes
from Xlib import X

# SuperTuxKart default keyboard bindings, player 1
ACCEL = ecodes.KEY_UP
BRAKE = ecodes.KEY_DOWN
LEFT = ecodes.KEY_LEFT
RIGHT = ecodes.KEY_RIGHT
DRIFT = ecodes.KEY_V
FIRE = ecodes.KEY_SPACE
NITRO = ecodes.KEY_N

# Motion window in seconds, also the release delay once the stick rests:
# longer than the gap between two reports at the slowest stick speed
WINDOW = 0.15

# Travel over the window, in device counts, before a direction key goes down
MIN_TRAVEL = 2

# An axis counts from this share of the other one: a push straight ahead
# does not steer, a diagonal does both
AXIS_SHARE = 0.4

# Second left press within this delay, in seconds: fire, not drift
DOUBLE_CLICK = 0.4

# A shorter tap can fall between two game frames, unseen
FIRE_HOLD = 0.1

# Held keys re-evaluated at this pace while the stick moves
TICK = 0.02

NEVER = float("-inf")


def log(message):
    print(f"dnf-stk-mouse: {message}", file=sys.stderr, flush=True)


class Keys:
    """Game keys held through a virtual keyboard, from mouse events."""

    def __init__(self, keyboard):
        self.keyboard = keyboard
        self.held = set()
        self.moves = collections.deque()
        self.last_press = NEVER
        self.fire_until = None

    def set(self, code, down):
        if down == (code in self.held):
            return
        self.keyboard.write(ecodes.EV_KEY, code, int(down))
        self.keyboard.syn()
        if down:
            self.held.add(code)
        else:
            self.held.discard(code)

    def reset(self):
        """Release every key, forget pending moves and clicks."""
        for code in list(self.held):
            self.set(code, False)
        self.moves.clear()
        self.last_press = NEVER
        self.fire_until = None

    def feed(self, event, now):
        if event.type == ecodes.EV_REL and event.code == ecodes.REL_X:
            self.moves.append((now, event.value, 0))
        elif event.type == ecodes.EV_REL and event.code == ecodes.REL_Y:
            self.moves.append((now, 0, event.value))
        elif event.type == ecodes.EV_KEY and event.code == ecodes.BTN_LEFT:
            self.left(event.value, now)
        elif event.type == ecodes.EV_KEY and event.code == ecodes.BTN_RIGHT:
            self.set(NITRO, event.value != 0)

    # The first click of a double click drifts a moment, without effect
    def left(self, value, now):
        if value == 0:
            self.set(DRIFT, False)
        elif now - self.last_press > DOUBLE_CLICK:
            self.last_press = now
            self.set(DRIFT, True)
        else:
            self.last_press = NEVER
            self.set(FIRE, True)
            self.fire_until = now + FIRE_HOLD

    def update(self, now):
        while self.moves and now - self.moves[0][0] > WINDOW:
            self.moves.popleft()
        dx = sum(move[1] for move in self.moves)
        dy = sum(move[2] for move in self.moves)
        self.axis(dx, dy, LEFT, RIGHT)

        # Stick pushed forward: pointer up, negative Y
        self.axis(dy, dx, ACCEL, BRAKE)
        if self.fire_until is not None and now >= self.fire_until:
            self.fire_until = None
            self.set(FIRE, False)

    def axis(self, travel, other, negative, positive):
        moving = abs(travel) >= max(MIN_TRAVEL, AXIS_SHARE * abs(other))
        self.set(negative, moving and travel < 0)
        self.set(positive, moving and travel > 0)

    def timeout(self):
        """Wake up to release keys, sleep while nothing moves."""
        busy = self.moves or self.fire_until is not None
        return TICK if busy else None


class Focus:
    """Whether the game window is the X11 active window (EWMH)."""

    def __init__(self, pid):
        self.pid = pid
        self.display = Xlib.display.Display()
        self.root = self.display.screen().root
        self.active = self.display.intern_atom("_NET_ACTIVE_WINDOW")
        self.wm_pid = self.display.intern_atom("_NET_WM_PID")
        self.root.change_attributes(event_mask=X.PropertyChangeMask)
        self.game = self.query()

    def fileno(self):
        return self.display.fileno()

    def query(self):
        try:
            prop = self.root.get_full_property(self.active, X.AnyPropertyType)
            if prop is None or len(prop.value) == 0 or prop.value[0] == 0:
                return False
            window = self.display.create_resource_object(
                "window", prop.value[0]
            )
            prop = window.get_full_property(self.wm_pid, X.AnyPropertyType)

        # Window destroyed between both reads
        except Xlib.error.XError:
            return False
        return prop is not None and prop.value[0] == self.pid

    def changed(self):
        """Read pending X events: True when the game gained or lost focus."""
        moved = False
        for _ in range(self.display.pending_events()):
            event = self.display.next_event()
            if event.type == X.PropertyNotify and event.atom == self.active:
                moved = True
        if not moved:
            return False
        was, self.game = self.game, self.query()
        return was != self.game


def open_mice():
    """Physical mice: injected devices (Talon, ours) are never read back."""
    mice = []
    for path in evdev.list_devices():
        node = os.path.basename(path)
        sysfs = os.path.realpath(f"/sys/class/input/{node}/device")
        if sysfs.startswith("/sys/devices/virtual/"):
            continue
        try:
            device = evdev.InputDevice(path)
        except OSError:
            continue
        caps = device.capabilities()
        rel = caps.get(ecodes.EV_REL, [])
        button = ecodes.BTN_LEFT in caps.get(ecodes.EV_KEY, [])
        if ecodes.REL_X in rel and ecodes.REL_Y in rel and button:
            mice.append(device)
        else:
            device.close()
    return mice


def read(selector, mouse, keys):
    """Feed a mouse's pending events to `keys`, or drop them if None."""
    now = time.monotonic()
    try:
        for event in mouse.read():
            if keys is not None:
                keys.feed(event, now)
    except BlockingIOError:
        pass

    # Unplugged: the other mice keep driving
    except OSError:
        log(f"{mouse.path} lost")
        selector.unregister(mouse)
        mouse.close()


def drive(game):
    mice = open_mice()
    if not mice:
        raise OSError("no readable mouse")
    focus = Focus(game.pid)
    selector = selectors.DefaultSelector()

    # Readable once the game has exited
    selector.register(os.pidfd_open(game.pid), selectors.EVENT_READ)
    selector.register(focus, selectors.EVENT_READ, focus)
    for mouse in mice:
        log(f"reading {mouse.path} ({mouse.name})")
        selector.register(mouse, selectors.EVENT_READ, mouse)

    keyboard = evdev.UInput(
        {ecodes.EV_KEY: [ACCEL, BRAKE, LEFT, RIGHT, DRIFT, FIRE, NITRO]},
        name="DNF SuperTuxKart mouse",
        bustype=ecodes.BUS_VIRTUAL,
    )
    with keyboard:
        keys = Keys(keyboard)
        try:
            while game.poll() is None:
                for selected, _ in selector.select(keys.timeout()):
                    source = selected.data
                    if source is focus:
                        if focus.changed():
                            keys.reset()
                    elif source is not None:
                        read(selector, source, keys if focus.game else None)
                keys.update(time.monotonic())
        finally:
            keys.reset()


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    game = subprocess.Popen(sys.argv[1:])
    try:
        drive(game)

    # No input/uinput rights, no mouse, no X11: the game runs as usual
    except (OSError, evdev.UInputError, Xlib.error.DisplayError) as error:
        log(f"mouse driving off: {error}")
    sys.exit(game.wait())


if __name__ == "__main__":
    main()
