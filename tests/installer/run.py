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
  the disk passphrase, the disk is not erased.

On the installed system, all collect the garbage (`dnf/` stays, a GC root),
then back up again (`just backup-admin`): the first backup is kept, renamed
with its date. QEMU's user network is 10.0.2.0/24: the zone gets `10.1`.

    dnf-installer-test --iso ISO [--scenario scripted|interactive|resume|all]
                       [--workdir DIR] [--keep]

Logs: `<workdir>/<scenario>/serial.log`.
"""

import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

import pexpect
import pexpect.fdpexpect

PASSWORD = "password1"
PASSPHRASE = "dnf-test-pass"
DOMAIN = "example.org"
STICK_LABEL = "SECOURS"
SHELL_PROMPT = r"nixos@dnf-install:~\]\$"
SCENARIOS = ["scripted", "interactive", "resume"]

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


def log(msg):
    print(f"[ \033[1;36mDNF\033[0m ] \033[1;35mTEST\033[0m • {msg}", flush=True)


class Failure(Exception):
    pass


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

    def cable(self, up):
        self.execute("set_link", name="net0", up=up)

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
    """One run of `dnf-vm`, its serial console wrapped in pexpect."""

    def __init__(self, dir, iso, usb, ports):
        self.dir = dir
        self.ssh_port, self.unlock_port = ports
        serial = os.path.join(dir, "serial.sock")
        qmp = os.path.join(dir, "qmp.sock")
        for path in (serial, qmp):
            if os.path.exists(path):
                os.unlink(path)
        cmd = ["dnf-vm", "--state", dir, "--serial", serial, "--qmp", qmp, "--usb", usb]
        cmd += ["--ssh-port", str(self.ssh_port), "--unlock-port", str(self.unlock_port)]
        if iso:
            cmd += ["--iso", iso]
        self.proc = subprocess.Popen(cmd)
        try:
            self.qmp = Qmp(qmp)
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
            raise Failure(f"console: no {pattern!r} after {timeout}s ({type(e).__name__})")

    def shell(self, command, timeout=120):
        """Runs a command at the shell prompt, returns its output.

        The markers are split by `""` in what is typed: only the output of
        `echo` joins them, the echo of the command line never matches.
        """
        self.type(f'echo __BE""GIN__; {command}; echo __E""ND__$?__\r')
        self.expect(r"__BEGIN__\r?\n", timeout)
        self.expect(r"__END__(\d+)__", timeout)
        out, rc = self.console.before, int(self.console.match.group(1))
        self.expect(SHELL_PROMPT)
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


def boot_installer(dir, iso, usb, ports, offline):
    vm = Vm(dir, iso, usb, ports)
    try:
        if offline:
            vm.qmp.cable(False)
        log("Booting the installer ISO" + (", cable unplugged..." if offline else "..."))
        vm.expect(SHELL_PROMPT, timeout=600)
        vm.type("stty rows 50 cols 160\r")
        vm.expect(SHELL_PROMPT)

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


def fetch_deploy_key(vm, path):
    """The `nix` key of the new system: the way in after the reboot."""
    out = vm.shell("sudo base64 -w0 /mnt/home/nix/.ssh/id_ed25519")
    with open(path, "wb") as f:
        f.write(base64.b64decode(out.strip().splitlines()[-1]))
    os.chmod(path, 0o600)


def check_installed(dir, usb, ports, key, encrypted):
    vm = Vm(dir, None, usb, ports)
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


def scenario(name, iso, workdir):
    dir = os.path.join(workdir, name)
    shutil.rmtree(dir, ignore_errors=True)
    os.makedirs(dir)
    usb = os.path.join(dir, "stick.img")
    make_stick(usb)
    ports = (free_port(), free_port())
    key = os.path.join(dir, "nix-key")
    encrypted = name != "scripted"
    install = {"scripted": install_scripted, "interactive": install_interactive, "resume": install_resumed}[name]
    log(f"Scenario {name} in {dir}")

    vm = boot_installer(dir, iso, usb, ports, offline=name == "scripted")
    try:
        install(vm)
        fetch_deploy_key(vm, key)
        vm.type("sudo umount -R /mnt; sudo poweroff\r")
    except BaseException:
        vm.stop(timeout=0)
        raise
    vm.stop(timeout=180)
    check_installed(dir, usb, ports, key, encrypted)
    check_backup(dir, usb)
    log(f"Scenario {name}: OK")


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--iso", required=True, help="generic installer ISO file")
    p.add_argument("--scenario", choices=SCENARIOS + ["all"], default="all")
    p.add_argument(
        "--workdir",
        default=os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "dnf-installer-test"),
        help="disks and logs, about 25 GB a scenario (default: %(default)s)",
    )
    p.add_argument("--keep", action="store_true", help="keep the disks after a success")
    args = p.parse_args()

    workdir = os.path.abspath(args.workdir)
    names = SCENARIOS if args.scenario == "all" else [args.scenario]
    failed = []
    for name in names:
        try:
            scenario(name, os.path.abspath(args.iso), workdir)
            if not args.keep:
                os.unlink(os.path.join(workdir, name, "disk.qcow2"))

        # Any error fails the scenario, not the run: the next one still runs.
        except (Failure, OSError, subprocess.CalledProcessError) as e:
            log(f"Scenario {name} FAILED: {e}\n  serial log: {os.path.join(workdir, name, 'serial.log')}")
            failed.append(name)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
