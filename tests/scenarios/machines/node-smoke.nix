# Smoke: validates the forTest replug (nixpkgs/system owned by driver,
# specialArgs injected) on a minimal host. core (and thus sops) disabled
# until the secret fixtures land in a later phase.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-smoke";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testModule = {

    # Isolate the replug: no sops yet.
    darkone.system.core.enable = false;
  };

  testScript = ''
    node1.wait_for_unit("multi-user.target")
    node1.succeed("true")
  '';
}
