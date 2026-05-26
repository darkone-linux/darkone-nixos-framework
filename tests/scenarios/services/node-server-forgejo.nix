# Service test: forgejo on a "server" profile host (core + real sops).
# Boots server1 only; the zone's gateway (gw1) is data-only.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-server-forgejo";
  workspace = ../../workspaces/node/configs/server-forgejo;
  host = "server1";

  testScript = ''
    server1.wait_for_unit("multi-user.target")
    server1.wait_for_unit("forgejo.service")
    server1.succeed("systemctl is-active forgejo")
  '';
}
