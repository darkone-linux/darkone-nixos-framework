# L3 — multi-host network simulation. Replugs a subset of a workspace's hosts
# into the NixOS Test Driver, each on its zone VLAN (see `vlans.nix`).
#
# :::caution[Risk 5 — specialArgs recursion (spec §9.3)]
# Setting `_module.args = nodeDef.specialArgs` per-node recurses: the driver
# force-evaluates `node.virtualisation.vlans`, which merges every node module
# (`modules/service/nfs.nix` takes `network` via its function head); resolving
# that argument through `_module.args` requires `config`, which requires the
# merge again. Fix: hoist the workspace-shared specialArgs (identical across
# every node of the workspace) to the driver-level `node.specialArgs`, where
# they are external and need no `config` lookup. Only the truly per-node bits
# (`host`, `zone`) flow through `_module.args`.
# :::

{ pkgs, inputs }:
{
  name,
  workspace,
  hosts ? null,
  testScript,
}:
let
  inherit (pkgs) lib;
  ws = import ./workspace.nix { inherit inputs; } workspace;
  vlans = import ./vlans.nix { inherit lib; };
  selected = if hosts == null then ws.hostNames else hosts;

  # Partition `mkNodeArgs` output into shared vs per-node. Every node in a
  # workspace shares the same workspace inventory (hosts, network, users, ...),
  # the same nixpkgs/dnfLib instances, and the same workDir — only `host`
  # (and its derived `zone`) actually vary.
  sharedKeys = [
    "dnfConfig"
    "hosts"
    "network"
    "users"
    "userNixosProfiles"
    "workDir"
    "pkgs-stable"
    "dnfLib"
  ];
  perNodeKeys = [
    "host"
    "zone"
  ];

  # Any node yields the shared subset; pick the first by alphabetical name.
  refSpecialArgs = (ws.nodeOf (builtins.head ws.hostNames)).specialArgs;
  sharedSpecialArgs = lib.getAttrs sharedKeys refSpecialArgs;
in
pkgs.testers.runNixOSTest {
  inherit name testScript;

  # Each node owns its nixpkgs config (matches `mkNodeTest`): the framework's
  # `nixpkgs.config` settings would otherwise clash with the driver's
  # read-only pkgs.
  node.pkgsReadOnly = false;

  # Driver-level: shared specialArgs reach every node as external args, so
  # module function heads (`{ network, hosts, ... }`) resolve without ever
  # touching `_module.args`.
  node.specialArgs = sharedSpecialArgs;

  nodes = lib.genAttrs selected (
    host:
    let
      nodeDef = ws.nodeOf host;
    in
    {
      imports = nodeDef.modules ++ [
        ./test-tuning.nix
        (vlans.forHost (ws.hostByName host))

        # Per-node specialArgs — only the values that truly differ between
        # nodes. `_module.args` is safe here because no top-level config eval
        # closes over `host`/`zone` before the module merge resolves them.
        { _module.args = lib.getAttrs perNodeKeys nodeDef.specialArgs; }
      ];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 4096;
      };
    }
  );
}
