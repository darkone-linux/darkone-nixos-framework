"""DNF installer test: `darkone new` end to end, in a QEMU VM.

Boots the generic installer ISO (`dnf-vm`), drives `darkone new` on its serial
console with pexpect, reboots on the installed disk and checks the system and
the key backup. The real network is used: what a newcomer downloads, the test
downloads.

- `scripted`: booted without network, plugged in once tty1 waits for it;
  answers file, `--non-interactive`, clear disk, backup passphrase from a
  file, the stick named by the answers;
- `interactive`: every question answered on the console, encrypted disk, stick
  chosen, then unplugged and plugged back in over QMP; the first boot is
  unlocked through the initrd sshd (`dnf-unlock`).

On the installed system, both collect the garbage (`dnf/` stays, a GC root),
then back up again (`just backup-admin`): the first backup is kept, renamed
with its date.

    dnf-installer-test --iso ISO [--scenario scripted|interactive|all]
                       [--workdir DIR] [--keep]

Logs: `<workdir>/<scenario>/serial.log`. Spec: .specs/dnf/
projet-procedure-demarrage-dnf.md, § Assistant : lot 4.
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

# Serial input has a 16-byte FIFO: faster typing drops characters.
TYPE_CHUNK = 8
TYPE_PAUSE = 0.02

UP, DOWN, RIGHT, LEFT = "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D"
ENTER = "\r"

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
"""


def log(msg):
    print(f"[ \033[1;36mDNF\033[0m ] \033[1;35mTEST\033[0m • {msg}", flush=True)


class Failure(Exception):
    pass


class Qmp:
    """QEMU machine protocol: plugs the USB stick out and back in."""

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
        self.console.logfile_read = open(os.path.join(dir, "serial.log"), "a")

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

        # Offline, tty1 waits for a cable or a Wi-Fi, then goes on by itself.
        if offline:
            wait_for("tty1 waiting for the network", lambda: _on_tty1(vm, "-f bin/dnf-assistant"), 240)
            vm.qmp.cable(True)
            log("tty1 waits for the network: cable plugged in.")

        # tty1 launches the assistant by itself: the newcomer's path.
        wait_for("darkone on tty1", lambda: _on_tty1(vm, "-x darkone"), 180)
        log("tty1 runs darkone new by itself.")
    except BaseException:
        vm.stop(timeout=0)
        raise
    return vm


def _on_tty1(vm, match):
    try:
        vm.shell(f"pgrep -t tty1 {match}")
        return True
    except Failure:
        return False


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


def install_interactive(vm):
    log("darkone new, every question on the console (encrypted disk)...")
    vm.type("darkone new --dnf-url path:$DNF_SOURCE\r")
    steps = [
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
        ("Disk passphrase", PASSPHRASE + ENTER),
        ("Disk passphrase, again", PASSPHRASE + ENTER),
        ("and install\\?", LEFT + ENTER),
    ]
    for prompt, keys in steps:
        vm.expect(prompt)
        time.sleep(0.5)
        vm.type(keys)
    log("Installing...")
    vm.expect("USB stick for the backup", timeout=5400)

    # "Skip for now", declined: back to the choice, then the stick.
    time.sleep(0.5)
    vm.type(DOWN + DOWN + ENTER)
    vm.expect("Skip the backup\\?")
    time.sleep(0.5)
    vm.type(ENTER)
    vm.expect("USB stick for the backup")
    time.sleep(0.5)
    vm.type(ENTER)
    vm.expect("Unplug the USB stick", timeout=300)
    time.sleep(2)
    vm.qmp.unplug_stick()
    vm.expect("Plug it back in", timeout=120)
    vm.qmp.plug_stick()
    vm.expect("Backup written and read back", timeout=300)
    vm.expect("Done:", timeout=60)
    vm.expect(SHELL_PROMPT)
    log("Backup written, stick unplugged, plugged back in, read back.")


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
        log(f"Installed system: running, no failed unit, /etc/nixos clean, encrypted={encrypted}.")
        collect_garbage(ports[0], key)
        backup_again(ports[0], key)
        ssh(ports[0], key, "nix", "sudo systemctl poweroff", check=False)
    except BaseException:
        vm.stop(timeout=0)
        raise
    vm.stop()


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
    encrypted = name == "interactive"
    log(f"Scenario {name} in {dir}")

    vm = boot_installer(dir, iso, usb, ports, offline=name == "scripted")
    try:
        install_scripted(vm) if name == "scripted" else install_interactive(vm)
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
    p.add_argument("--scenario", choices=["scripted", "interactive", "all"], default="all")
    p.add_argument(
        "--workdir",
        default=os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "dnf-installer-test"),
        help="disks and logs, about 25 GB a scenario (default: %(default)s)",
    )
    p.add_argument("--keep", action="store_true", help="keep the disks after a success")
    args = p.parse_args()

    workdir = os.path.abspath(args.workdir)
    names = ["scripted", "interactive"] if args.scenario == "all" else [args.scenario]
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
