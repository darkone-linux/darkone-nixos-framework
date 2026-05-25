# L2 — single-node simulation. Replugs one workspace host into the NixOS
# Test Driver (see spec §8/§9.2).
#
# Aim: use.

{ pkgs, inputs }:
{
  name,
  workspace,
  host,
  testModule ? { },
  testScript,
}:
let
  ws = import ./workspace.nix { inherit inputs; } workspace;
  nodeDef = ws.nodeOf host;
in
pkgs.testers.runNixOSTest {
  inherit name testScript;

  # DNF modules (e.g. system/hardware.nix) set `nixpkgs.config`. Let each node
  # own its nixpkgs config instead of the driver's read-only pkgs — this
  # resolves the `nixpkgs.config` conflict and builds from the project's own
  # nixpkgs (same revision as production).
  node.pkgsReadOnly = false;

  # Single node: the global node.specialArgs is sufficient.
  node.specialArgs = nodeDef.specialArgs;

  nodes.${host} = {
    imports = nodeDef.modules ++ [
      ./test-tuning.nix
      testModule
    ];
  };
}
