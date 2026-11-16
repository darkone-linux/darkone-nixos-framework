"""DNF installer test: `darkone new` end to end, in a QEMU VM.

Boots the generic installer ISO (`dnf-vm`), picks "New network" in the tty1
menu over QMP, drives `darkone new` on its serial console with pexpect, reboots
on the installed disk and checks the system and the key backup. The real
network is used: what a newcomer downloads, the test downloads.

- `scripted`: booted without network, plugged in once tty1 waits for it;
  answers file, `--non-interactive`, clear disk, backup passphrase from a
  file, the stick named by the answers, cache.nixos.org as an extra cache
  (the option reaches `nixos-install`, nothing else changes);
- `interactive`: every question answered on the console, encrypted disk, stick
  chosen, then unplugged and plugged back in over QMP; the first boot is
  unlocked through the initrd sshd (`dnf-unlock`);
- `resume`: as `interactive`, the link cut during `nixos-install` (its retry
  loop takes over), then Ctrl-C and `darkone new` again: "Resume" asks only
  the disk passphrase, the disk is not erased;
- `preflight`: no install. Cable cut, `darkone new` stops on its pre-flight
  error before any question; cable back, "Check again" reaches the first one;
- `gateway`: two machines, not part of `all` (two installs). The admin host is
  installed as in `scripted`, its disk kept. A machine with two cards boots
  the ISO, entry 2 of its tty1 menu. On the admin host, `darkone add gateway`:
  `--dry-run` first, where the pairing code read on the serial console of the
  gateway is typed, then `--answers --non-interactive`. The recabling pause of
  `full-install` is answered over QMP. Then: zone lease of the admin host,
  name of the gateway, Internet through it.

On the installed system, the installs collect the garbage (`dnf/` stays, a GC
root), then back up again (`just backup-admin`): the first backup is kept,
renamed with its date. QEMU's user network is 10.0.2.0/24: the zone gets `10.1`.

Network of `gateway`, UDP links on 127.0.0.1 (`dnf-box`, `dnf-vm --link`, the
learning switch `Switch`):

    Internet -- box: QEMU's user network, 10.0.2.0/24, behind the switch
                 |-- admin host, card net0
                 `-- gateway, card net0 (WAN)
    admin host, card net1 -- gateway, card net1 (LAN, zone 10.1.0.0/16)

Recabling: `set_link` off on net0 of the admin host, then on on its net1,
unplugged until then. The host reaches the admin host through the box, by
ssh, as long as net0 is plugged; then by its serial console alone.

`gateway` runs the `darkone` of the image, copied to the disk of the admin
host and first in its PATH. The project pins the generator the framework
locks; an image built on another one carries it no further than that
(`just test-installer gateway '' <generator checkout>`).

    dnf-installer-test --iso ISO [--scenario NAME|all] [--workdir DIR]
                       [--memory MiB] [--keep] [--reuse-admin]

`--memory`: RAM of every VM of the run, to measure the threshold of the
pre-flight checks (`MIN_RAM_MIB` of the generator); the gateway keeps its own.
`--reuse-admin`: `gateway` on the admin host a previous run installed (its
disk, kept by a failure or `--keep`, back as installed).

Logs: `<workdir>/<scenario>/serial.log`; `gateway`: `admin/` and `gateway/`
under it, and `box.log`.
"""

import argparse
import base64
import json
import os
import re
import selectors
import shutil
import socket
import subprocess
import sys
import threading
import time

import pexpect
import pexpect.fdpexpect

PASSWORD = "password1"
PASSPHRASE = "dnf-test-pass"
DOMAIN = "example.org"
STICK_LABEL = "SECOURS"
SHELL_PROMPT = r"nixos@dnf-install:~\]\$"
SCENARIOS = ["preflight", "scripted", "interactive", "resume"]
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
END = r"__END__(\d+)__"

# `gateway`. Admin host: the login of ANSWERS_SCRIPTED, a prompt the test sets.
ADMIN_LOGIN = "alice"
ADMIN_PS1 = "dnf-test@admin$ "
ADMIN_PROMPT = r"dnf-test@admin\$ "
GATEWAY = "gw"
GATEWAY_MEMORY = 4096

# Cards, net0 then net1: box then LAN (admin host), WAN then LAN (gateway).
ADMIN_MACS = ("52:54:00:d0:0a:01", "52:54:00:d0:0a:02")
GATEWAY_MACS = ("52:54:00:d0:0b:01", "52:54:00:d0:0b:02")

# First lease of the box, what `dnf-box --forward` aims at: the admin host.
ADMIN_BOX_IP = "10.0.2.15"

# GC root of the `darkone` of the image, on the disk of the admin host.
DARKONE_ROOT = "/nix/var/nix/gcroots/dnf-installer-test"

# 10.0 overlaps QEMU's user network (10.0.2.0/24): the next free /16.
ZONE_ROW = r"Zone +main, 10\.1\.0\.0/16, definitive"
IP_PREFIX = "10.1"

# Serial input has a 16-byte FIFO: faster typing drops characters.
TYPE_CHUNK = 8
TYPE_PAUSE = 0.02

UP, DOWN, RIGHT, LEFT = "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D"
ENTER = "\r"
CTRL_C = "\x03"

# QMP `send-key` names (qcodes) of what is typed on tty1; a digit or a
# lowercase letter is its own name.
QCODES = {"\r": "ret", " ": "spc"}

# `resume`: link cut CUT_AFTER s into the downloads, down CUT_MAX s at most.
# A transfer in flight stalls; Nix drops it after `stalled-download-timeout`
# (300 s), then its 5 `download-attempts` (~4 s of backoff) fail link down.
CUT_AFTER = 20
CUT_MAX = 600
INTERRUPT_AFTER = 30

# Logged by install-here once `nixos-install` succeeded.
INSTALLED = "Copying the project to /etc/nixos"

# Zone `main`: the gateway takes 1.1, the admin host 2.1.
GATEWAY_LAN_IP = f"{IP_PREFIX}.1.1"
ADMIN_LAN_IP = f"{IP_PREFIX}.2.1"

# Every question of `darkone new`, in order, and its answer; a resume asks
# none of them.
QUESTIONS = [
    ("Language and keyboard", ENTER),
    ("Timezone", ENTER),
    ("Your full name", "Alice Martin" + ENTER),
    ("Your login", ENTER),
    ("Your email", ENTER),
    ("Your password", PASSWORD + ENTER),
    ("Your password, again", PASSWORD + ENTER),
    ("Network domain \\(definitive\\)", DOMAIN + ENTER),
    ("Name of this machine", ENTER),
    ("Encrypt the disk\\?", ENTER),
]
LUKS_PASSPHRASE = [
    ("Disk passphrase", PASSPHRASE + ENTER),
    ("Disk passphrase, again", PASSPHRASE + ENTER),
]

ANSWERS_SCRIPTED = f"""version: 1
admin:
  login: "alice"
  name: "Alice Martin"
  passwordHash: '{{hash}}'
network:
  domain: "{DOMAIN}"
host:
  hostname: "poste"
disk:
  encrypt: false
locale:
  language: "fr_FR.UTF-8"
backup:
  device: "/dev/disk/by-label/{STICK_LABEL}"
cache:
  url: "https://cache.nixos.org"
  publicKey: "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
"""

# WAN and disk left to the proposals: the card of the route, the only disk.
ANSWERS_GATEWAY = f"""version: 1
address: "{{address}}"
host:
  hostname: "{GATEWAY}"
nics:
  lan: ["{{lan}}"]
confirm: true
"""

# Questions on the console of `darkone add gateway` nobody is there to answer.
UNANSWERED = [
    (r"Continue anyway\? \(y/N\)", "`install` warns and asks to go on: none of its pre-flight warnings is expected here"),
    (r"Are you sure to format disks", "`install` asks its confirmation again: DNF_INSTALL_CONFIRMED did not reach it"),
    (r"\[sudo\] [^\r\n]*: ", "sudo asks a password"),
]
PAIRING_PROMPT = r"Pairing code \(PPPPPP-FFFF\): "


def log(msg):
    print(f"[ \033[1;36mDNF\033[0m ] \033[1;35mTEST\033[0m • {msg}", flush=True)


class Failure(Exception):
    pass


def plain(text):
    """Console output without its colors: `ip` paints the addresses."""
    return ANSI.sub("", text)


def qcode(char):
    """QMP key name of a character typed on tty1."""
    if char in QCODES:
        return QCODES[char]
    if re.fullmatch(r"[0-9a-z]", char):
        return char
    raise Failure(f"QMP send-key: no key name for {char!r}")


class Qmp:
    """QEMU machine protocol: the cable, the USB stick, the tty1 keyboard."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        for _ in range(100):
            try:
                self.sock.connect(path)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise Failure(f"QMP: no socket at {path}, QEMU did not start")
        self.file = self.sock.makefile("rw")
        self.file.readline()
        self.execute("qmp_capabilities")

    def execute(self, command, **arguments):
        self.file.write(json.dumps({"execute": command, "arguments": arguments}) + "\n")
        self.file.flush()
        while True:
            reply = json.loads(self.file.readline())
            if "error" in reply:
                raise Failure(f"QMP {command}: {reply['error']}")
            if "return" in reply:
                return reply["return"]

    def cable(self, up, card="net0"):
        self.execute("set_link", name=card, up=up)

    def send_keys(self, text):
        """The emulated keyboard, read by tty1: the serial console is another tty."""
        for char in text:
            self.execute("send-key", keys=[{"type": "qcode", "data": qcode(char)}])
            time.sleep(0.1)

    def unplug_stick(self):
        self.execute("device_del", id="stick")

    def plug_stick(self):
        self.execute(
            "device_add",
            driver="usb-storage",
            bus="xhci.0",
            drive="stick-raw",
            id="stick",
            removable=True,
        )


class Vm:
    """One run of `dnf-vm`, its serial console wrapped in pexpect.

    `links`: its cards, on UDP links instead of the user network (`dnf-vm
    --link`); `unplugged`: those whose cable is out from the start.
    """

    def __init__(self, dir, iso, usb, ports, memory=None, links=(), unplugged=()):
        self.dir = dir
        self.name = os.path.basename(dir)
        self.prompt = SHELL_PROMPT
        self.ssh_port, self.unlock_port = ports
        serial = os.path.join(dir, "serial.sock")
        qmp = os.path.join(dir, "qmp.sock")

        # `sun_path` holds 108 bytes: past that QEMU cannot listen on its sockets.
        if len(os.fsencode(serial)) > 107:
            raise Failure(f"workdir too deep: {serial} is over 107 bytes, a Unix socket's limit")
        for path in (serial, qmp):
            if os.path.exists(path):
                os.unlink(path)
        cmd = ["dnf-vm", "--state", dir, "--serial", serial, "--qmp", qmp]
        if usb:
            cmd += ["--usb", usb]
        if links:
            for link in links:
                cmd += ["--link", link]
        else:
            cmd += ["--ssh-port", str(self.ssh_port), "--unlock-port", str(self.unlock_port)]
        if iso:
            cmd += ["--iso", iso]
        if memory:
            cmd += ["--memory", str(memory)]
        self.proc = subprocess.Popen(cmd)
        try:
            self.qmp = Qmp(qmp)
            for card in unplugged:
                self.qmp.cable(False, card)
            self.sock = socket.socket(socket.AF_UNIX)
            self.sock.connect(serial)
        except BaseException:
            self.proc.kill()
            raise
        self.console = pexpect.fdpexpect.fdspawn(
            self.sock.fileno(), timeout=120, encoding="utf-8", codec_errors="replace"
        )
        self.log = os.path.join(dir, "serial.log")
        self.console.logfile_read = open(self.log, "a")

    def mark(self):
        """Where the serial log ends now: `since` reads what came after."""
        self.console.logfile_read.flush()
        return os.path.getsize(self.log)

    def since(self, mark):
        with open(self.log, "rb") as f:
            f.seek(mark)
            return f.read().decode("utf-8", "replace")

    def type(self, text):
        for i in range(0, len(text), TYPE_CHUNK):
            self.console.send(text[i : i + TYPE_CHUNK])
            time.sleep(TYPE_PAUSE)

    def expect(self, pattern, timeout=120):
        try:
            return self.console.expect(pattern, timeout=timeout)
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            raise Failure(f"console of {self.name}: no {pattern!r} after {timeout}s ({type(e).__name__}), see {self.log}")

    def shell(self, command, timeout=120):
        """Runs a command at the shell prompt, returns its output.

        The markers are split by `""` in what is typed: only the output of
        `echo` joins them, the echo of the command line never matches.
        """
        self.type(f'echo __BE""GIN__; {command}; echo __E""ND__$?__\r')
        self.expect(r"__BEGIN__\r?\n", timeout)
        self.expect(END, timeout)
        out, rc = self.console.before, int(self.console.match.group(1))
        self.expect(self.prompt)
        if rc != 0:
            raise Failure(f"`{command}` failed ({rc}):\n{out}")
        return out

    def stop(self, timeout=120):
        """Waits for a poweroff, then quits QEMU; `timeout=0` quits at once."""
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.qmp.execute("quit")
            self.proc.wait(30)
        self.console.logfile_read.close()


def ssh(port, key, user, command, stdin=None, check=True):
    cmd = ["ssh", "-q", "-i", key, "-p", str(port), "-o", "BatchMode=yes"]
    cmd += ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
    cmd += ["-o", "ConnectTimeout=5", f"{user}@127.0.0.1", command]
    r = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise Failure(f"ssh {user}: `{command}` failed ({r.returncode}):\n{r.stdout}{r.stderr}")
    return r


def wait_for(what, probe, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if probe():
            return
        time.sleep(5)
    raise Failure(f"{what}: nothing after {timeout}s")


def make_stick(path):
    """64 MB, one FAT partition: smaller than any install disk (< 20 GB)."""
    subprocess.run(["truncate", "-s", "64M", path], check=True)
    subprocess.run(["sfdisk", "-q", path], input="type=c\n", text=True, check=True)
    subprocess.run(
        ["mkfs.vfat", "--offset", "2048", "-n", STICK_LABEL, path],
        check=True,
        capture_output=True,
    )


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def free_udp_ports(count):
    """Held together until all are drawn: no port twice."""
    socks = [socket.socket(type=socket.SOCK_DGRAM) for _ in range(count)]
    try:
        for s in socks:
            s.bind(("127.0.0.1", 0))
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


def wait_shell(vm):
    """The autologin shell of the installer ISO on the serial console."""
    vm.expect(SHELL_PROMPT, timeout=600)
    vm.type("stty rows 50 cols 160\r")
    vm.expect(SHELL_PROMPT)


def boot_installer(dir, iso, usb, ports, offline, memory, net=None):
    vm = Vm(dir, iso, usb, ports, memory, **(net or {}))
    try:
        if offline:
            vm.qmp.cable(False)
        log("Booting the installer ISO" + (", cable unplugged..." if offline else "..."))
        wait_shell(vm)

        # Offline, tty1 waits for a cable or a Wi-Fi, then shows its menu.
        if offline:
            wait_for("tty1 waiting for the network", lambda: _on_tty1(vm, "-f bin/dnf-assistant"), 240)
            vm.qmp.cable(True)
            log("tty1 waits for the network: cable plugged in.")

        # The newcomer's path: the tty1 menu, once online, "1" for a new
        # network. Read off the screen (`/dev/vcs1`): a key sent earlier would
        # land in the Wi-Fi prompt of the wait.
        wait_for("the menu on tty1", lambda: _succeeds(vm, "sudo grep -qF 'Choice [1-3]:' /dev/vcs1"), 180)
        vm.qmp.send_keys("1\r")
        wait_for("darkone on tty1", lambda: _on_tty1(vm, "-x darkone"), 60)
        log("tty1 menu: 1 runs darkone new.")
    except BaseException:
        vm.stop(timeout=0)
        raise
    return vm


def _succeeds(vm, command):
    try:
        vm.shell(command)
        return True
    except Failure:
        return False


def _on_tty1(vm, match):
    return _succeeds(vm, f"pgrep -t tty1 {match}")


def install_scripted(vm):
    hash_ = vm.shell(f"printf %s '{PASSWORD}' | mkpasswd -m yescrypt -s").strip().splitlines()[-1]
    answers = ANSWERS_SCRIPTED.replace("{hash}", hash_)
    vm.type("cat > /tmp/answers.yaml <<'EOF'\r" + answers.replace("\n", "\r") + "EOF\r")
    vm.expect(SHELL_PROMPT)
    vm.shell(f"printf %s '{PASSPHRASE}' > /tmp/backup && chmod 600 /tmp/backup")
    log("darkone new --answers --non-interactive (clear disk)...")
    out = vm.shell(
        "darkone new --answers /tmp/answers.yaml --non-interactive --yes "
        "--backup-passphrase-file /tmp/backup --dnf-url path:$DNF_SOURCE",
        timeout=5400,
    )
    if "Done:" not in out:
        raise Failure("darkone new returned without its final message")
    if not re.search(r"Cache +https://cache\.nixos\.org, for the install only", out):
        raise Failure("the plan does not show the extra cache of the answers")
    if not re.search(ZONE_ROW, out):
        raise Failure(f"the plan does not show the zone prefix {IP_PREFIX}")


def answer(vm, steps):
    """Waits for each prompt, then types its answer; `None` only waits."""
    for prompt, keys in steps:
        vm.expect(prompt)
        if keys is not None:
            time.sleep(0.5)
            vm.type(keys)


def ask_everything(vm):
    """`darkone new` from its first question to the start of the install."""
    log("darkone new, every question on the console (encrypted disk)...")
    vm.type("darkone new --dnf-url path:$DNF_SOURCE\r")
    answer(vm, [("Pre-flight checks done", None)] + QUESTIONS + LUKS_PASSPHRASE)
    answer(vm, [(ZONE_ROW, None), ("and install\\?", LEFT + ENTER)])
    log("Installing...")


def install_interactive(vm):
    ask_everything(vm)
    vm.expect("USB stick for the backup", timeout=5400)

    # "Skip for now", declined: back to the choice, then the stick.
    time.sleep(0.5)
    vm.type(DOWN + DOWN + ENTER)
    vm.expect("Skip the backup\\?")
    time.sleep(0.5)
    vm.type(ENTER)
    vm.expect("USB stick for the backup")
    backup_and_finish(vm)


def backup_and_finish(vm):
    """At the choice of the stick: the first one, unplugged and plugged back in
    over QMP, read back. No reboot: the test reads the new disk first."""
    time.sleep(0.5)
    vm.type(ENTER)
    vm.expect("Unplug the USB stick", timeout=300)
    time.sleep(2)
    vm.qmp.unplug_stick()
    vm.expect("Plug it back in", timeout=120)
    vm.qmp.plug_stick()
    vm.expect("Backup written and read back", timeout=300)
    vm.expect("Done:", timeout=60)
    vm.expect("Reboot now\\?")
    time.sleep(0.5)
    vm.type(ENTER)
    vm.expect(SHELL_PROMPT)
    log("Backup written, stick unplugged, plugged back in, read back; reboot declined.")


def install_resumed(vm):
    """Link cut, then Ctrl-C, during `nixos-install`; `darkone new` resumes."""
    if not _succeeds(vm, 'test -d "$XDG_RUNTIME_DIR"'):
        raise Failure("no XDG_RUNTIME_DIR on the serial console: no answers kept, no resume")
    ask_everything(vm)
    cut_link(vm)
    interrupt(vm)
    resume(vm)


def cut_link(vm):
    """Cut while downloads run, back once `nixos-install` fails or CUT_MAX."""
    vm.expect(r"Installing [\w-]+\.\.\.", timeout=1800)

    # Nix's progress bar counts the downloads; none shown, cut all the same.
    # Waits read the console: unread output would stall the guest's serial port.
    i = vm.expect([r"MiB DL", INSTALLED, pexpect.TIMEOUT], timeout=600)
    if i == 2:
        log("No download progress on the console: the link is cut all the same.")
    if i == 1 or vm.expect([INSTALLED, pexpect.TIMEOUT], timeout=CUT_AFTER) == 0:
        raise Failure("nixos-install ended before the link was cut")
    vm.qmp.cable(False)
    log(f"Link cut during nixos-install, {CUT_MAX} s at most...")
    i = vm.expect([r"nixos-install failed \(attempt 1/3\)", INSTALLED, pexpect.TIMEOUT], timeout=CUT_MAX)

    # Back at once: attempt 2 needs it, Nix's backoff covers the DHCP lease.
    vm.qmp.cable(True)
    if i == 1:
        raise Failure("nixos-install ended with the link cut")
    if i == 0:
        log("nixos-install failed with the link cut, link back: the retry loop takes over.")
    else:
        log(f"Link back after {CUT_MAX} s, nixos-install still running: Nix's own retries held.")


def interrupt(vm):
    """Ctrl-C once downloads run again: the project and /mnt stay for a resume."""
    retried = False
    while True:
        i = vm.expect([r"MiB DL", r"Retry\? \[y/N\]", INSTALLED], timeout=900)
        if i == 0:
            break
        if i == 2:
            raise Failure("nixos-install ended before Ctrl-C: nothing left to resume")

        # Attempts 2 and 3 ran before the lease came back: the operator's retry.
        if retried:
            raise Failure("nixos-install failed again after a retry, link back")
        log("Three attempts failed, the link came back late: retry answered.")
        retried = True
        time.sleep(0.5)
        vm.type("y" + ENTER)
    if vm.expect([INSTALLED, pexpect.TIMEOUT], timeout=INTERRUPT_AFTER) == 0:
        raise Failure("nixos-install ended before Ctrl-C: nothing left to resume")
    vm.console.send(CTRL_C)
    again = [r"nixos-install failed \(attempt \d/3\)", r"Retry\? \[y/N\]"]
    if vm.expect([SHELL_PROMPT] + again) != 0:
        raise Failure("Ctrl-C did not stop install-here: its retry loop ran nixos-install again")
    log("Ctrl-C during nixos-install.")

    # The retry loop must stop too: a background attempt would race the resume.
    wait_for(
        "install-here stopped by Ctrl-C (its retry loop goes on?)",
        lambda: _succeeds(vm, "! pgrep -f 'install-here|nixos-install|--store /mnt'"),
        120,
    )
    if not _succeeds(vm, "mountpoint -q /mnt"):
        raise Failure("/mnt is no longer mounted after Ctrl-C: nothing to resume")

    # Same networks as the first run, or the plan differs and the resume is refused.
    wait_for("a route, the link back", lambda: _succeeds(vm, "ip -4 route get 1.1.1.1 >/dev/null"), 120)


def resume(vm):
    """The Resume choice: the disk passphrase only, the plan of the first run,
    the disk not erased."""
    mark = vm.mark()
    log("darkone new again, Resume...")
    vm.type("darkone new --dnf-url path:$DNF_SOURCE\r")
    if vm.expect([r"It cannot be resumed: ([^\r\n]*)", "Previous install"]) == 0:
        raise Failure(f"no Resume offered: {vm.console.match.group(1)}")
    time.sleep(0.5)
    vm.type(ENTER)
    answer(vm, [("Type the disk passphrase of the first attempt again", None)] + LUKS_PASSPHRASE)
    vm.expect("Resuming the install\\.\\.\\.")
    asked = vm.since(mark)
    once = [prompt for prompt, _ in QUESTIONS] + ["and install\\?", "Resume the answers"]
    again = [prompt for prompt in once if re.search(prompt, asked)]
    if again:
        raise Failure(f"the resume asked again: {again}")
    if "kept from the previous attempt" not in asked:
        raise Failure("the plan of the resume does not keep the disk")
    vm.expect("Resuming on the disk of the previous attempt, not erased", timeout=300)
    log("Resumed: only the disk passphrase asked, the disk kept.")
    vm.expect("USB stick for the backup", timeout=5400)
    backup_and_finish(vm)
    after = vm.since(mark)
    for erased in ("Erasing and mounting the disks", "Unmounting the previous attempt", "Removing the project"):
        if erased in after:
            raise Failure(f"the resume did not keep the first attempt: {erased!r}")


def preflight(vm):
    """Cable cut: `darkone new` stops before its first question. Cable back:
    "Check again", the first item, passes and the questions start."""
    vm.qmp.cable(False)
    wait_for("the default route gone, cable cut", lambda: _succeeds(vm, "! ip -4 route get 1.1.1.1"), 60)
    log("Cable cut, darkone new...")
    vm.type("darkone new --dnf-url path:$DNF_SOURCE\r")
    if vm.expect(["Pre-flight checks failed", "Language and keyboard"], timeout=240) == 1:
        raise Failure("a question came before the pre-flight error, cable cut")
    vm.expect(r"unreachable|name not resolved")
    error = vm.console.match.group(0)
    vm.expect("The install cannot start")
    log(f"Pre-flight error before the first question: {error}.")

    # The DHCP lease takes a few seconds: each failed check brings the choice back.
    vm.qmp.cable(True)
    for _ in range(6):
        time.sleep(10)
        vm.type(ENTER)
        vm.expect("Checking memory, network and clock")
        if vm.expect(["Pre-flight checks done", "Pre-flight checks failed"]) == 0:
            break
        vm.expect("The install cannot start")
    else:
        raise Failure("the pre-flight checks still fail a minute after the cable came back")
    vm.expect("Language and keyboard")
    log("Cable back, Check again: checks passed, first question shown.")
    vm.console.send(CTRL_C)
    vm.expect(SHELL_PROMPT)


def fetch_deploy_key(vm, path):
    """The `nix` key of the new system: the way in after the reboot."""
    out = vm.shell("sudo base64 -w0 /mnt/home/nix/.ssh/id_ed25519")
    with open(path, "wb") as f:
        f.write(base64.b64decode(out.strip().splitlines()[-1]))
    os.chmod(path, 0o600)


def check_installed(dir, usb, ports, key, encrypted, memory, net=None):
    vm = Vm(dir, None, usb, ports, memory, **(net or {}))
    try:
        if encrypted:
            log("First boot: unlocking through the initrd sshd...")
            wait_for(
                "remote unlock",
                lambda: ssh(ports[1], key, "root", "dnf-unlock", stdin=PASSPHRASE + "\n", check=False).returncode == 0,
                600,
            )
        wait_for("sshd of the new system", lambda: ssh(ports[0], key, "nix", "true", check=False).returncode == 0, 900)
        state = ssh(ports[0], key, "nix", "timeout 600 systemctl is-system-running --wait", check=False).stdout.strip()
        failed = ssh(ports[0], key, "nix", "systemctl --failed --no-legend --plain").stdout.strip()
        if state != "running" or failed:
            raise Failure(f"system {state}, failed units:\n{failed}")
        dirty = ssh(ports[0], key, "nix", "git -C /etc/nixos status --porcelain").stdout.strip()
        if dirty:
            raise Failure(f"/etc/nixos is not clean:\n{dirty}")
        ssh(ports[0], key, "nix", "test -f /etc/xdg/autostart/dnf-welcome.desktop")
        crypt = ssh(ports[0], key, "nix", "lsblk -nro TYPE").stdout.split()
        if ("crypt" in crypt) != encrypted:
            raise Failure(f"disk encryption: expected {encrypted}, lsblk says {crypt}")
        prefix = f'grep -Eq \'^ +ipPrefix: "{re.escape(IP_PREFIX)}"$\' /etc/nixos/etc/config.yaml'
        if ssh(ports[0], key, "nix", prefix, check=False).returncode != 0:
            raise Failure(f"etc/config.yaml: the zone prefix is not {IP_PREFIX}")

        # Written by the backup of the install: the welcome page shows no warning.
        ssh(ports[0], key, "nix", "test -s /var/lib/dnf/backup-admin")
        log(f"Installed system: running, no failed unit, /etc/nixos clean, encrypted={encrypted}, "
            f"zone {IP_PREFIX}, backup witness.")
        check_admin_desktop(ports[0], key)
        collect_garbage(ports[0], key)
        backup_again(ports[0], key)
        ssh(ports[0], key, "nix", "sudo systemctl poweroff", check=False)
    except BaseException:
        vm.stop(timeout=0)
        raise
    vm.stop()


def check_admin_desktop(port, key):
    """What the new admin finds: project on `main`, README in their language,
    Ghostty, terminal programs off the grid, the Local network folder, Zed
    allowed on the emulated GPU."""
    run = lambda cmd: ssh(port, key, "nix", cmd).stdout.strip()
    branch = run("git -C /etc/nixos branch --show-current")
    if branch != "main":
        raise Failure(f"/etc/nixos is on branch {branch!r}, not main")
    title = run("head -1 /etc/nixos/README.md")
    french = "LANG=fr_" in run("cat /etc/locale.conf")
    if title != ("# Votre réseau DNF" if french else "# Your DNF network"):
        raise Failure(f"README.md title {title!r}, locale french={french}")
    run("test ! -e /etc/nixos/README.fr.md")
    login = run("getent passwd 1000 | cut -d: -f1")
    run(f"test -x /etc/profiles/per-user/{login}/bin/ghostty")
    run(f"test ! -e /etc/profiles/per-user/{login}/bin/gimp")
    hidden = run(
        f"for id in btop htop vim; do "
        f"[ -e /etc/profiles/per-user/{login}/share/applications/$id.desktop ] || continue; "
        f"sudo grep -qx NoDisplay=true ~{login}/.local/share/applications/$id.desktop || exit 1; "
        f"echo $id; done"
    )
    if not hidden:
        raise Failure("none of btop, htop, vim installed: no hidden launcher to check")
    run(f"test -e /etc/profiles/per-user/{login}/share/applications/dnf-network-sources.desktop")
    run(f"sudo test -e ~{login}/.config/autostart/dnf-network-folder.desktop")
    run("grep -q ZED_ALLOW_EMULATED_GPU /etc/pam/environment")
    log(f"Admin desktop: branch main, README ({'fr' if french else 'en'}), Ghostty, "
        f"{hidden.split()} hidden, network folder, Zed on a VM.")


def collect_garbage(port, key):
    """The weekly GC of a DNF host keeps `dnf/`, what `just` imports."""
    ssh(port, key, "nix", "sudo nix-store -q --roots $(readlink -f /etc/nixos/dnf) | grep -q '^/etc/nixos/dnf '")
    ssh(port, key, "nix", "sudo nix-store --gc >/dev/null 2>&1")
    ssh(port, key, "nix", "cd /etc/nixos && just --list >/dev/null")
    log("Garbage collected: dnf/ kept, just works.")


def backup_again(port, key):
    """`just backup-admin` on the installed system, then its check."""
    ssh(port, key, "nix", "umask 077 && cat > /tmp/backup-pass", stdin=PASSPHRASE)
    device = f"/dev/disk/by-label/{STICK_LABEL}"
    for recipe in ("backup-admin", "backup-check"):
        ssh(port, key, "nix", f"cd /etc/nixos && just {recipe} {device} /tmp/backup-pass")
    ssh(port, key, "nix", "rm /tmp/backup-pass")
    log("Backed up again from the installed system, and checked.")


def check_backup(dir, usb):
    """Opened from the host, as a newcomer would after losing the disk."""
    name = f"dnf-backup-{DOMAIN}"
    out = os.path.join(dir, "backup")
    os.makedirs(out, exist_ok=True)
    files = subprocess.run(
        ["mdir", "-b", "-i", f"{usb}@@1M", "::"], capture_output=True, text=True, check=True
    ).stdout.split()
    if not any(re.fullmatch(rf"::/{re.escape(name)}\.\d{{8}}-\d{{6}}\.tar\.age", f) for f in files):
        raise Failure(f"the first backup is not kept under a dated name: {files}")
    for f in (f"{name}.tar.age", f"{name}.README.txt"):
        subprocess.run(["mcopy", "-o", "-i", f"{usb}@@1M", f"::{f}", out], check=True)
    pass_file = os.path.join(out, "passphrase")
    with open(pass_file, "w") as f:
        f.write(PASSPHRASE)
    listing = subprocess.run(
        ["bash", "-c", 'set -o pipefail; AGE_PASSPHRASE_FD=3 age -d -j batchpass "$1" 3<"$2" | tar -t', "_"]
        + [os.path.join(out, f"{name}.tar.age"), pass_file],
        capture_output=True,
        text=True,
    )
    if listing.returncode != 0:
        raise Failure(f"the backup does not open: {listing.stderr}")
    names = listing.stdout.split()
    expected = ["nix/id_ed25519", "nix/keys.txt", "infra.key", "project.bundle", "README.txt"]
    missing = [e for e in expected if f"dnf-backup/{e}" not in names]
    if missing:
        raise Failure(f"the backup misses {missing}: {names}")
    log("Backup opened from the host: keys and project inside, the first one kept.")


class Switch(threading.Thread):
    """Learning switch, UDP on 127.0.0.1: a frame to a known MAC goes to its
    port alone, the rest floods. Behind the hub of `dnf-box`, slirp sees no
    flow between two machines: it would take it for its NAT and reset it."""

    def __init__(self, count):
        super().__init__(daemon=True)
        drawn = free_udp_ports(2 * count)
        own, self.peers = drawn[:count], drawn[count:]
        self.socks = []
        for port, peer in zip(own, self.peers):
            s = socket.socket(type=socket.SOCK_DGRAM)
            s.bind(("127.0.0.1", port))
            self.socks.append((s, ("127.0.0.1", peer)))
        self.ports = own
        self.running = True
        self.start()

    def run(self):
        where = {}
        sel = selectors.DefaultSelector()
        for i, (s, _) in enumerate(self.socks):
            sel.register(s, selectors.EVENT_READ, i)
        while self.running:
            for key, _ in sel.select(timeout=1):
                i = key.data
                try:
                    frame = key.fileobj.recv(65536)
                except OSError:
                    continue
                if len(frame) < 14:
                    continue
                where[frame[6:12]] = i

                # Bit 0 of the first byte: broadcast or multicast.
                dst = where.get(frame[0:6]) if not frame[0] & 1 else None
                for j in [dst] if dst is not None else range(len(self.socks)):
                    if j != i:
                        s, peer = self.socks[j]
                        try:
                            s.sendto(frame, peer)
                        except OSError:
                            pass

    def link(self, i):
        """`LOCAL,PEER` of the machine on port `i`, as `dnf-vm --link` takes it."""
        return f"{self.peers[i]},{self.ports[i]}"

    def stop(self):
        self.running = False
        self.join(5)
        for s, _ in self.socks:
            s.close()


class Box:
    """`dnf-box`: QEMU's user network, port 0 of a switch the machines plug
    into (`link`)."""

    def __init__(self, dir, machines, forward):
        self.switch = Switch(1 + machines)
        self.log = os.path.join(dir, "box.log")
        cmd = ["dnf-box", "--forward", str(forward), "--link", self.switch.link(0)]
        self.out = open(self.log, "w")
        self.proc = subprocess.Popen(cmd, stdout=self.out, stderr=subprocess.STDOUT)

        # A port taken meanwhile, an option QEMU refuses: it exits at once.
        time.sleep(1)
        if self.proc.poll() is not None:
            self.stop()
            raise Failure(f"dnf-box exited ({self.proc.returncode}), see {self.log}")

    def link(self, machine):
        """`LOCAL,PEER` of the card of machine `machine` (0, 1...) on the box."""
        return self.switch.link(1 + machine)

    def stop(self):
        self.proc.terminate()
        self.proc.wait(30)
        self.out.close()
        self.switch.stop()


def gateway_network(box):
    """The cards of each machine of `gateway`, as `Vm` takes them: net0 on the
    box, net1 on the UDP link between both."""
    admin_lan, gw_lan = free_udp_ports(2)
    return {
        "admin": {
            "links": [f"{ADMIN_MACS[0]},{box.link(0)}", f"{ADMIN_MACS[1]},{admin_lan},{gw_lan}"],
            "unplugged": ["net1"],
        },
        "gateway": {
            "links": [f"{GATEWAY_MACS[0]},{box.link(1)}", f"{GATEWAY_MACS[1]},{gw_lan},{admin_lan}"],
        },
    }


def keep_darkone(vm):
    """On the ISO, the admin host installed under /mnt: its lease is the one
    the box forwards to, and the `darkone` of the image goes to its disk,
    kept by a GC root."""
    addrs = plain(vm.shell("ip -4 -o addr show scope global"))
    if f" {ADMIN_BOX_IP}/" not in addrs:
        raise Failure(f"the admin host did not get {ADMIN_BOX_IP}, the first lease of the box, where its ssh forward goes:\n{addrs}")
    vm.shell(
        'p=$(dirname "$(dirname "$(readlink -f "$(command -v darkone)")")")'
        f' && sudo nix copy --no-check-sigs --to /mnt "$p" && sudo ln -sfn "$p" /mnt{DARKONE_ROOT}',
        timeout=600,
    )


def login(vm, port, key):
    """A shell of the admin on the serial console of the installed host, the
    terminal `darkone` runs on. No getty there (`console=ttyS0` is the
    image's): started for this boot only."""
    ssh(port, key, "nix", "sudo systemctl start serial-getty@ttyS0.service")
    vm.expect(r"login: ", timeout=60)
    vm.type(ADMIN_LOGIN + ENTER)
    vm.expect(r"(?i)(password|mot de passe)[^\r\n]*:", timeout=30)
    time.sleep(0.5)
    vm.type(PASSWORD + ENTER)

    # The login shell is zsh, its prompt themed: a plain bash, a prompt the
    # test waits for. `''`: the echo of this line is not that prompt. Typed
    # again until it shows: zsh may not read yet. No `TMOUT` (R32): the prompt
    # stays idle while the gateway boots.
    vm.prompt = ADMIN_PROMPT
    ps1 = ADMIN_PS1.replace("@", "@''")
    for _ in range(3):
        time.sleep(5)
        vm.type(f"exec env -u TMOUT PS1='{ps1}' bash --norc --noprofile\r")
        if vm.console.expect([ADMIN_PROMPT, pexpect.TIMEOUT], timeout=20) == 0:
            break
    else:
        raise Failure(f"no shell for {ADMIN_LOGIN} on the serial console of the admin host, see {vm.log}")
    vm.type("stty rows 50 cols 160\r")
    vm.expect(vm.prompt)


def prepare_admin(vm):
    """What the chain needs of the admin host, checked before it starts; then
    the `darkone` of the image first in PATH, in the project."""
    if not _succeeds(vm, "sudo -n true"):
        raise Failure("sudo asks a password on the admin host: every recipe of the chain would stop on its prompt")

    # The admin tooling installs `darkone` (`darkone.admin.nix`).
    vm.shell("test -x /run/current-system/sw/bin/darkone")
    vm.shell(f'export PATH="$(readlink -f {DARKONE_ROOT})/bin:$PATH" && cd /etc/nixos')
    if not _succeeds(vm, "darkone add gateway --help"):
        raise Failure(
            "the darkone of this image has no `add gateway`: build the image on a generator that has it "
            "(just test-installer gateway '' <generator checkout>)"
        )
    used, installed = vm.shell('readlink -f "$(command -v darkone)" /run/current-system/sw/bin/darkone').split()
    log("Admin host: sudo without password, darkone of the image "
        + ("is the installed one." if used == installed else "first in PATH (the project pins another generator)."))


def boot_admin(dir, usb, ports, key, memory, net):
    """The installed admin host, plugged into the box, its admin logged in."""
    vm = Vm(dir, None, usb, ports, memory, **net)
    try:
        log("Booting the admin host on its disk...")
        wait_for("sshd of the admin host, through the box", lambda: ssh(ports[0], key, "nix", "true", check=False).returncode == 0, 900)
        ssh(ports[0], key, "nix", "timeout 600 systemctl is-system-running --wait", check=False)
        login(vm, ports[0], key)
        prepare_admin(vm)
    except BaseException:
        vm.stop(timeout=0)
        raise
    return vm


def boot_gateway(dir, iso, net):
    """The machine to install: the ISO, then entry 2 of its tty1 menu."""
    vm = Vm(dir, iso, None, (None, None), GATEWAY_MEMORY, **net)
    try:
        log("Booting the gateway on the installer ISO...")
        wait_shell(vm)
        wait_for("the menu on tty1 of the gateway", lambda: _succeeds(vm, "sudo grep -qF 'Choice [1-3]:' /dev/vcs1"), 180)
        vm.qmp.send_keys("2\r")
        wait_for("a pairing code on tty1 of the gateway", lambda: _succeeds(vm, "sudo grep -qF 'Pairing code:' /dev/vcs1"), 60)
        log("tty1 menu of the gateway: 2 shows a pairing code.")
    except BaseException:
        vm.stop(timeout=0)
        raise
    return vm


def read_pairing(vm):
    """`dnf-pair` on the serial console of the gateway: what its screen tells
    the operator. Returns the address, the code and the card of each MAC."""
    mark = vm.mark()
    vm.type("dnf-pair\r")
    vm.expect(r"Pairing code: (?:\x1b\[[0-9;]*m)?(\d{6}-\d{4})", timeout=60)
    code = vm.console.match.group(1)
    time.sleep(1)
    vm.console.send(CTRL_C)
    vm.expect("Back to the shell")
    vm.expect(SHELL_PROMPT)
    screen = ANSI.sub("", vm.since(mark))
    address = re.search(r"- IP: (\d+(?:\.\d+){3})", screen)
    cards = {mac: card for card, mac in re.findall(r"^\s*(\S+)\s+((?:[0-9a-f]{2}:){5}[0-9a-f]{2})\s", screen, re.M)}
    if not address or set(GATEWAY_MACS) - set(cards):
        raise Failure(f"dnf-pair on the gateway shows no address, or not its two cards:\n{screen}")
    if not _succeeds(vm, f"sudo grep -qF 'Pairing code: {code}' /dev/vcs1"):
        raise Failure("tty1 of the gateway does not show the pairing code of its serial console")
    return address.group(1), code, cards


def follow(vm, command, steps, unanswered=UNANSWERED):
    """Types `command` at the prompt and follows it: each step is a pattern
    to wait for, its timeout, and what to do once shown. Returns the output.

    The command reads the console: a question nobody answers would hold it
    until the timeout. One of `unanswered` (pattern, what it means) fails at
    once instead."""
    vm.type(f'echo __BE""GIN__; {command}; echo __E""ND__$?__\r')
    vm.expect(r"__BEGIN__\r?\n")
    mark = vm.mark()
    stops = [END] + [pattern for pattern, _ in unanswered]

    def tail():
        return "\n".join(ANSI.sub("", vm.since(mark)).splitlines()[-40:])

    def wait(pattern, timeout):
        """0: `pattern` shown; 1: the command ended."""

        # A window: megabytes of progress bars pile up between two steps, and
        # each read would search them all again.
        try:
            i = vm.console.expect([pattern] + stops, timeout=timeout, searchwindowsize=8192)
        except (pexpect.TIMEOUT, pexpect.EOF) as e:
            raise Failure(
                f"console of {vm.name}: no {pattern!r} after {timeout}s ({type(e).__name__}), see {vm.log}\n{tail()}"
            )
        if i >= 2:
            raise Failure(f"console of {vm.name}: {unanswered[i - 2][1]}, see {vm.log}\n{tail()}")
        return i

    for pattern, timeout, then in steps:
        if wait(pattern, timeout) == 1:
            raise Failure(f"`{command}` ended ({vm.console.match.group(1)}) before {pattern!r}, see {vm.log}\n{tail()}")
        if then:
            then()
    wait(END, 300)
    rc = int(vm.console.match.group(1))
    vm.expect(vm.prompt)
    if rc != 0:
        raise Failure(f"`{command}` failed ({rc}), see {vm.log}\n{tail()}")
    return ANSI.sub("", vm.since(mark))


def step(pattern, timeout, then=None, said=None):
    """A step of `follow` that also tells how far the run went."""

    def reached():
        if then:
            then()
        if said:
            log(said)

    return pattern, timeout, reached


def add_gateway(admin, gw):
    """`darkone add gateway` on the admin host: dry run, then the real one."""
    address, code, cards = read_pairing(gw)
    wan, lan = (cards[mac] for mac in GATEWAY_MACS)
    log(f"Gateway at {address}, WAN {wan}, LAN {lan}: its pairing code read on its serial console.")
    answers = ANSWERS_GATEWAY.format(address=address, lan=lan)
    admin.type("cat > /tmp/gateway.yaml <<'EOF'\r" + answers.replace("\n", "\r") + "EOF\r")
    admin.expect(admin.prompt)
    darkone = "darkone add gateway --answers /tmp/gateway.yaml --non-interactive"

    # Checks `yq`, the edit and the generator, changes nothing; `_pair` asks
    # the code here, the machine stays paired for the real run.
    log("darkone add gateway --dry-run, the pairing code typed on the admin host...")
    out = follow(
        admin,
        darkone + " --dry-run",
        [
            (PAIRING_PROMPT, 600, lambda: admin.type(code + ENTER)),
            (r"paired: deploy key in, code dead", 120, None),
            (r"Dry run: nothing changed", 900, None),
        ],
    )
    for row in (f"{wan} ({GATEWAY_MACS[0]}), to the box, default route", f"fixed address {ADMIN_LAN_IP} (main:2.1)"):
        if row not in out:
            raise Failure(f"the plan of the dry run does not show {row!r}:\n{out}")
    dirty = admin.shell("git status --porcelain").strip()
    if dirty:
        raise Failure(f"the dry run changed the project:\n{dirty}")
    wait_for("Paired on tty1 of the gateway", lambda: _succeeds(gw, "sudo grep -qF 'Paired:' /dev/vcs1"), 30)
    log("Dry run: paired by the code, plan and diff shown, project unchanged; tty1 of the gateway says Paired.")

    def recable():
        admin.qmp.cable(False, "net0")
        time.sleep(2)
        admin.qmp.cable(True, "net1")
        log("Recabled: admin host unplugged from the box, plugged into the LAN card of the gateway.")

    log("darkone add gateway: declaration, install, recabling, apply...")
    follow(
        admin,
        darkone,
        [
            step(r"not written yet", 900),
            step(rf"Installing {GATEWAY} on {re.escape(address)} \(just full-install\)", 1800, said="Declared and committed."),
            step(r"will answer SSH only on its LAN", 1800),
            step(r"Launching installation \(install\)", 3600, said="Recabling announced, install prepared: nixos-anywhere..."),
            step(r"Waiting for reboot", 7200, said=f"{GATEWAY} installed, rebooting."),
            step(r"Now unplug this machine from the box", 900, then=recable),
            step(rf"{GATEWAY} is back at {re.escape(GATEWAY_LAN_IP)}", 1800, said=f"{GATEWAY} answers on its LAN: configure, apply..."),
            step(r"Last reboot", 5400),
            step(r"Applying this machine, behind its gateway", 900, said=f"{GATEWAY} applied and rebooted: apply-local..."),
            step(r"Checking the network behind the gateway", 5400),
            step(r"Step 2 of 4 done", 600),
        ],

        # Paired by the dry run: asked again, the deploy key did not stay in.
        UNANSWERED + [(PAIRING_PROMPT, "the pairing code is asked again, the dry run left the gateway paired")],
    )
    log("darkone add gateway: Step 2 of 4 done.")


def check_behind_gateway(admin):
    """From the admin host, its cable to the box unplugged: the lease of its
    zone, the name of the gateway, the Internet through it, the project."""
    addrs = plain(admin.shell("ip -4 -o addr show scope global"))
    if f" {ADMIN_LAN_IP}/" not in addrs or f" {ADMIN_BOX_IP}/" in addrs:
        raise Failure(f"the admin host is not at {ADMIN_LAN_IP} alone, its address in the zone:\n{addrs}")
    name = admin.shell(f"getent ahostsv4 {GATEWAY}").split()
    if not name or name[0] != GATEWAY_LAN_IP:
        raise Failure(f"{GATEWAY} does not resolve to {GATEWAY_LAN_IP} on the admin host: {name}")
    route = plain(admin.shell("ip -4 -o route get 1.1.1.1"))
    if f" via {GATEWAY_LAN_IP} " not in route:
        raise Failure(f"the default route of the admin host is not {GATEWAY_LAN_IP}:\n{route}")
    admin.shell("curl -fsS -m 30 -o /dev/null https://cache.nixos.org/nix-cache-info")
    log(f"Admin host at {ADMIN_LAN_IP}, {GATEWAY} resolves to {GATEWAY_LAN_IP}, Internet through it.")

    dirty = admin.shell("git status --porcelain").strip()
    if dirty:
        raise Failure(f"/etc/nixos is not clean after darkone add gateway:\n{dirty}")
    if f"chore(gateway): add {GATEWAY}" not in admin.shell("git --no-pager log --format=%s -20"):
        raise Failure("no commit of the gateway declaration in /etc/nixos")
    state = admin.shell(
        f"sudo -i -u nix ssh nix@{GATEWAY} 'timeout 600 systemctl is-system-running --wait; systemctl --failed --no-legend --plain'",
        timeout=700,
    ).split("\n", 1)
    failed = state[1].strip() if len(state) > 1 else ""
    if state[0].strip() != "running" or failed:
        raise Failure(f"{GATEWAY} is {state[0].strip()}, failed units:\n{failed}")
    log(f"Project clean, declaration committed; {GATEWAY} running, no failed unit.")


def gateway(iso, dir, memory, reuse):
    """`darkone add gateway`, from an admin host installed as in `scripted`."""
    admin_dir, gateway_dir = os.path.join(dir, "admin"), os.path.join(dir, "gateway")
    disk = os.path.join(admin_dir, "disk.qcow2")
    usb = os.path.join(admin_dir, "stick.img")
    key = os.path.join(admin_dir, "nix-key")
    if reuse:
        if not (os.path.exists(disk) and os.path.exists(key)):
            raise Failure(f"--reuse-admin: no admin host under {admin_dir}, run the scenario once without it")
        back = subprocess.run(["qemu-img", "snapshot", "-a", "installed", disk], capture_output=True, text=True)
        if back.returncode != 0:
            raise Failure(f"--reuse-admin: {disk} does not go back to its install: {back.stderr.strip()}")
        shutil.rmtree(gateway_dir, ignore_errors=True)
    else:
        shutil.rmtree(dir, ignore_errors=True)
        os.makedirs(admin_dir)
        make_stick(usb)
    os.makedirs(gateway_dir)

    ports = (free_port(), None)
    box = Box(dir, 2, ports[0])
    net = gateway_network(box)
    machines = []
    try:
        if not reuse:
            vm = boot_installer(admin_dir, iso, usb, ports, offline=True, memory=memory, net=net["admin"])
            install_and_check(vm, install_scripted, admin_dir, usb, ports, key, False, memory, net["admin"], keep_darkone)

            # Powered off: what `--reuse-admin` goes back to.
            subprocess.run(["qemu-img", "snapshot", "-c", "installed", disk], check=True)
            log("Admin host installed and checked through the box, its disk kept.")
        admin = boot_admin(admin_dir, usb, ports, key, memory, net["admin"])
        machines.append(admin)
        gw = boot_gateway(gateway_dir, iso, net["gateway"])
        machines.append(gw)
        add_gateway(admin, gw)
        check_behind_gateway(admin)
    finally:
        for vm in machines:
            vm.stop(timeout=0)
        box.stop()


def scenario(name, iso, workdir, memory, reuse=False):
    dir = os.path.join(workdir, name)
    log(f"Scenario {name} in {dir}" + (f", {memory} MiB of RAM" if memory else ""))
    if name == "gateway":
        gateway(iso, dir, memory, reuse)
        log(f"Scenario {name}: OK")
        return
    shutil.rmtree(dir, ignore_errors=True)
    os.makedirs(dir)
    usb = os.path.join(dir, "stick.img")
    make_stick(usb)
    ports = (free_port(), free_port())
    key = os.path.join(dir, "nix-key")
    encrypted = name != "scripted"

    vm = boot_installer(dir, iso, usb, ports, offline=name == "scripted", memory=memory)
    if name == "preflight":
        try:
            preflight(vm)
        finally:
            vm.stop(timeout=0)
        log(f"Scenario {name}: OK")
        return

    install = {"scripted": install_scripted, "interactive": install_interactive, "resume": install_resumed}[name]
    install_and_check(vm, install, dir, usb, ports, key, encrypted, memory)
    log(f"Scenario {name}: OK")


def install_and_check(vm, install, dir, usb, ports, key, encrypted, memory, net=None, before_poweroff=None):
    """`install` on the booted ISO, then the installed system and its backup."""
    try:
        install(vm)
        fetch_deploy_key(vm, key)
        if before_poweroff:
            before_poweroff(vm)
        vm.type("sudo umount -R /mnt; sudo poweroff\r")
    except BaseException:
        vm.stop(timeout=0)
        raise
    vm.stop(timeout=180)
    check_installed(dir, usb, ports, key, encrypted, memory, net)
    check_backup(dir, usb)


def disks(dir):
    """The disk of every machine of a scenario, one directory each."""
    return [os.path.join(d, f) for d, _, files in os.walk(dir) for f in files if f == "disk.qcow2"]


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--iso", required=True, help="generic installer ISO file")
    p.add_argument("--scenario", choices=SCENARIOS + ["gateway", "all"], default="all")
    p.add_argument(
        "--workdir",
        default=os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "dnf-installer-test"),
        help="disks and logs, about 25 GB a scenario (default: %(default)s)",
    )
    p.add_argument("--memory", type=int, metavar="MiB", help="RAM of the VMs (default: dnf-vm's, 8192)")
    p.add_argument("--keep", action="store_true", help="keep the disks after a success")
    p.add_argument("--reuse-admin", action="store_true", help="gateway: skip the install of the admin host, take the one of the previous run")
    args = p.parse_args()

    workdir = os.path.abspath(args.workdir)
    names = SCENARIOS if args.scenario == "all" else [args.scenario]
    failed = []
    for name in names:
        try:
            scenario(name, os.path.abspath(args.iso), workdir, args.memory, args.reuse_admin)
            if not args.keep:
                for disk in disks(os.path.join(workdir, name)):
                    os.unlink(disk)

        # Any error fails the scenario, not the run: the next one still runs.
        except (Failure, OSError, subprocess.CalledProcessError) as e:
            log(f"Scenario {name} FAILED: {e}\n  logs: {os.path.join(workdir, name)}")
            failed.append(name)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
