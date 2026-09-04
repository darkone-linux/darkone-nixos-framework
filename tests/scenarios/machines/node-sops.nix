# Validates real sops in a VM: core enabled, secrets decrypted from the
# committed test store with the injected throwaway key.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-sops";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testScript = ''
    node1.wait_for_unit("multi-user.target")

    # Per-user hash decrypted before the accounts exist (neededForUsers).
    node1.succeed("test -s /run/secrets-for-users/user/nix/password-hash")

    # F4: the fleet default password reaches no host.
    node1.fail("test -e /run/secrets/default-password")
    node1.fail("test -e /run/secrets/default-password-hash")
  '';
}
