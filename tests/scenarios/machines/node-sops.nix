# Validates real sops in a VM: core enabled, secrets decrypted from the
# committed test store with the injected throwaway key.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-sops";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testScript = ''
    node1.wait_for_unit("multi-user.target")

    # default-password-hash secret was decrypted and placed by sops-nix.
    node1.succeed("test -s /run/secrets/default-password-hash")
  '';
}
