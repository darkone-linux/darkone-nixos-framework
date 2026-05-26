# Smoke: validates the forTest replug (nixpkgs/system owned by driver,
# specialArgs injected) on a minimal host. Boots the full stack via the
# seam (darkone.test.standalone); the cheapest "host comes up" check.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-smoke";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testScript = ''
    node1.wait_for_unit("multi-user.target")
    node1.succeed("true")
  '';
}
