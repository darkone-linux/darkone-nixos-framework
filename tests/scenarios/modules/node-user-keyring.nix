# Login keyring in a VM: a sealed keyring is set aside, never deleted, by the
# passwordless conversion (home-manager) and by the reset after an admin
# password change (PAM). It holds keys no app can ask for again (`safeStorage`).

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-user-keyring";
  workspace = ../../workspaces/node/configs/user-keyring;
  host = "node1";

  testModule = {
    darkone.graphic.gnome.enable = true;

    # `keyring-reset` only knows accounts with a hash file. Mutable: the test
    # changes its fingerprint, as `just passwd` does.
    users.users.darkone.hashedPasswordFile = pkgs.lib.mkForce "/var/lib/test-password-hash";

    # Binds the daemon's control socket: no gnome-keyring runs without a session.
    environment.systemPackages = [ pkgs.python3Minimal ];
  };

  testScript = ''
    node1.wait_for_unit("multi-user.target")
    node1.wait_for_unit("home-manager-darkone.service")

    keyrings = "~darkone/.local/share/keyrings"
    sealed = "~darkone/.local/share/keyrings.sealed"
    blob = "GnomeKeyring-test-blob"

    def as_user(cmd):
        node1.succeed(f"runuser -u darkone -- sh -c '{cmd}'")

    def seal():
        as_user(f"printf {blob} > {keyrings}/login.keyring")

    # Restart a second later: moved files are stamped to the second.
    def activate():
        node1.succeed("sleep 1; systemctl restart home-manager-darkone.service")

    def assert_plain():
        node1.succeed(f"test \"$(head -c 9 {keyrings}/login.keyring)\" = '[keyring]'")

    def assert_sealed_count(count):
        node1.succeed(f"test $(ls {sealed}/login.keyring.* | wc -l) -eq {count}")

    with subtest("fresh home: plain keyring seeded, nothing set aside"):
        assert_plain()
        node1.succeed(f"test -e {keyrings}/default")
        node1.fail(f"test -e {sealed}")

    with subtest("plain keyring: neither moved nor modified"):
        as_user(f"echo test-marker >> {keyrings}/login.keyring")
        activate()
        node1.succeed(f"grep -q test-marker {keyrings}/login.keyring")
        node1.fail(f"test -e {sealed}")

    with subtest("sealed keyring: moved as is with its keystore, plain one seeded"):
        seal()
        as_user(f"printf test-keystore > {keyrings}/user.keystore")
        activate()
        node1.succeed(f"grep -q {blob} {sealed}/login.keyring.*")
        node1.succeed(f"grep -q test-keystore {sealed}/user.keystore.*")
        node1.succeed(f"test $(stat -c %a {sealed}) = 700")
        node1.fail(f"test -e {keyrings}/user.keystore")
        assert_plain()

    with subtest("activation is idempotent"):
        activate()
        assert_sealed_count(1)

    with subtest("sealed keyring without keystore: moved, activation succeeds"):
        seal()
        activate()
        assert_sealed_count(2)
        assert_plain()

    with subtest("running daemon: sealed keyring left in place"):
        uid = node1.succeed("id -u darkone").strip()
        daemon_dir = f"/run/user/{uid}/keyring"
        node1.succeed(f"install -d -o darkone {daemon_dir}")
        node1.succeed(
            f"python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind(\"{daemon_dir}/control\")'"
        )
        seal()
        activate()
        node1.succeed(f"grep -q {blob} {keyrings}/login.keyring")
        assert_sealed_count(2)
        node1.succeed(f"rm -r {daemon_dir}")

    reset = node1.succeed(
        "grep -oE '/nix/store/[^ ]*keyring-reset' /etc/pam.d/login | head -1"
    ).strip()

    def password_changed(fingerprint):
        node1.succeed(f"printf {fingerprint} > /var/lib/test-password-hash")
        node1.succeed(f"PAM_USER=darkone {reset}")

    with subtest("PAM reset, first sight: records the fingerprint, moves nothing"):
        password_changed("hash-1")
        node1.succeed(f"grep -q {blob} {keyrings}/login.keyring")
        assert_sealed_count(2)

    with subtest("PAM reset, new password: moved as is, recreated by GNOME"):
        node1.succeed("sleep 1")
        as_user(f"printf test-keystore > {keyrings}/user.keystore")
        password_changed("hash-2")
        assert_sealed_count(3)
        node1.fail(f"test -e {keyrings}/login.keyring")
        node1.fail(f"test -e {keyrings}/user.keystore")

    with subtest("PAM reset, plain keyring: kept"):
        as_user(f"echo [keyring] > {keyrings}/login.keyring")
        password_changed("hash-3")
        assert_plain()
        assert_sealed_count(3)
  '';
}
