# User SSH keys in a VM: the `usr/users/<login>/authorized_keys` registry
# reaches sshd, and `enableVaultwardenSsh` wires rbw as the SSH agent. No
# Vaultwarden runs here: the agent config only needs its URL.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-user-ssh";
  workspace = ../../workspaces/node/configs/user-ssh;
  host = "node1";

  testScript = ''
    node1.wait_for_unit("multi-user.target")
    node1.wait_for_unit("home-manager-darkone.service")

    # Registry → sshd: the committed key, nothing from the home dir.
    node1.succeed("grep -q 'darkone@test-user-ssh' /etc/ssh/authorized_keys.d/darkone")
    node1.fail("test -e ~darkone/.ssh/authorized_keys")

    # rbw points at the zone Vaultwarden with the config.yaml email.
    cfg = "~darkone/.config/rbw/config.json"
    node1.succeed(f"grep -q '\"email\": *\"darkone@test.local\"' {cfg}")
    node1.succeed(f"grep -Eq '\"base_url\": *\"https?://[^\"]+\\.test\\.local\"' {cfg}")
    node1.succeed(f"grep -q 'pinentry-curses' {cfg}")

    # Agent socket: env var for ssh-add/ssh-keygen, IdentityAgent for ssh.
    node1.succeed("grep -q 'rbw/ssh-agent-socket' /etc/profiles/per-user/darkone/etc/profile.d/hm-session-vars.sh")
    node1.succeed("grep -q 'IdentityAgent .*rbw/ssh-agent-socket' ~darkone/.ssh/config")
    node1.succeed("test -x /etc/profiles/per-user/darkone/bin/rbw")
  '';
}
