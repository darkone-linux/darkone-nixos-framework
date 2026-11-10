# L4 — install scenario for a LUKS-encrypted btrfs server, exercising the
# `disko-server` workspace through `mkInstallTest` (L4 tier).

{ pkgs, inputs }:
(import ../../lib/mkInstallTest.nix { inherit pkgs inputs; }) {
  name = "node-disko-server-btrfs-luks";
  workspace = ../../workspaces/node/configs/disko-server;
  host = "server1";
}
