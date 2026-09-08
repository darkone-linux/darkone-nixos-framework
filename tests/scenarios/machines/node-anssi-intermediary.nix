# L2 — the `intermediary` ANSSI tier, booted. Guards the blockers of the
# 2026-09-08 audit (see .specs/security/05-palier-anssi.md): every one of them
# was invisible to evaluation, and B11 only surfaced here — a booted VM is the
# cheapest place that runs activation. Category `server` so the server-only
# subset (R62, R79) is covered too.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-anssi-intermediary";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testModule = {
    darkone.system.security = {
      level = "intermediary";
      category = "server";

      # The test driver logs in as root over the serial backdoor and gives it
      # an empty `hashedPasswordFile` for that (test-instrumentation.nix). R34
      # counts any such file as a credential — it cannot read its content — so
      # the assertion fires on an artefact no real host carries.
      exceptions.R34.rationale = "root credential injected by the NixOS test driver, not by DNF.";
    };
  };

  testScript = ''
    import re

    def auth_order(path):
        """Line numbers of the auth-stack landmarks in a rendered pam.d file."""
        text = node1.succeed(f"cat {path}")
        marks = {}
        for n, line in enumerate(text.splitlines(), 1):
            if not line.startswith("auth"):
                continue
            # Anchor on the rendered rule name, not the module: `login` also
            # carries a `unix-early` pam_unix rule 1400 ranks ahead of the one
            # faillock is meant to bracket.
            for key, pattern in (
                ("preauth", r"# faillock-preauth \(order"),
                ("authfail", r"# faillock-authfail \(order"),
                ("unix", r"# unix \(order"),
                ("deny", r"# deny \(order"),
            ):
                if key not in marks and re.search(pattern, line):
                    marks[key] = n
        return marks

    node1.wait_for_unit("multi-user.target")

    # B3 — an unknown sysctl key makes systemd-sysctl exit non-zero, and every
    # end-of-session check hangs on "no failed unit".
    node1.succeed("systemctl is-active systemd-sysctl.service")
    failed = node1.succeed("systemctl list-units --state=failed --no-legend")
    assert failed.strip() == "", f"failed units at intermediary: {failed}"

    # B2 — R13 used to disable IPv6 fleet-wide through an inverted tag.
    node1.succeed("test $(sysctl -n net.ipv6.conf.all.disable_ipv6) -eq 0")
    node1.succeed("ip -6 addr show lo | grep -q '::1/128'")

    # F8 — the constat this tier is meant to close.
    node1.succeed("test $(sysctl -n net.ipv4.conf.all.accept_redirects) -eq 0")

    # B1 — colmena escalates with `sudo -H --`, no TTY. `requiretty` here made
    # the fleet undeployable one generation after the sudoers landed.
    node1.succeed("setsid runuser -u nix -- sudo -n true < /dev/null")

    # B8 — faillock ranks are derived per service; hardcoded ones landed after
    # pam_deny on every stack but `login`, so preauth refused nothing.
    for service in ("login", "su", "sudo"):
        marks = auth_order(f"/etc/pam.d/{service}")
        for key in ("preauth", "unix", "authfail", "deny"):
            assert key in marks, f"{service}: no {key} rule in the auth stack"
        assert marks["preauth"] < marks["unix"] < marks["authfail"] < marks["deny"], (
            f"{service}: faillock out of order {marks}"
        )

    # B7 — SSH is key-only, so faillock never counts there; an `account` rule
    # would only ever refuse the rescue session a console lock-out earned.
    node1.fail("grep -q pam_faillock /etc/pam.d/sshd")

    # I2 — noexec on /tmp would break every Nix build unpacking a configure
    # script, so R28 moves the daemon's TMPDIR out of the way. The mount itself
    # is unobservable here: qemu-vm replaces `fileSystems` wholesale
    # (mkVMOverride), so /tmp options belong to the rendered-/etc check.
    node1.succeed("systemctl show nix-daemon -p Environment | grep -q TMPDIR=/var/tmp")

    # E2 — hidepid=2 blinds `ps` for administrators unless `proc` has members.
    # Kernels since 5.8 report `hidepid=2` back as `hidepid=invisible`.
    node1.succeed("findmnt -no OPTIONS /proc | grep -qE 'hidepid=(2|invisible)'")
    node1.succeed("getent group proc | grep -q nix")

    # B11 — a group *name* in `gid=` makes the /proc remount fail, and specialfs
    # leaves it unmounted: the `modprobe` activation snippet then cannot write
    # the kmod path, autoload falls back to a non-existent /sbin/modprobe, and
    # nftables dies at boot with the firewall down.
    node1.succeed("test \"$(cat /proc/sys/kernel/modprobe)\" != /sbin/modprobe")
    node1.succeed("systemctl is-active nftables.service")

    # R33 — the tier leans on sudo for accountability. Root's own credential is
    # not observable here: the driver overrides it to log in (see the R34
    # exception above), so only the SSH side is checked.
    node1.succeed("grep -qiE '^PermitRootLogin[[:space:]]+no$' /etc/ssh/sshd_config")

    # R62 at category server: obsolete protocols and desktop daemons off.
    node1.fail("systemctl is-enabled avahi-daemon.service")
    node1.fail("systemctl is-enabled cups.service")

    # R53/R56/R80 — the audit timers must survive the tier raise.
    timers = node1.succeed("systemctl list-timers --all --no-legend")
    assert "anssi-orphan-scan" in timers, timers
    assert "anssi-setuid-scan" in timers, timers
  '';
}
