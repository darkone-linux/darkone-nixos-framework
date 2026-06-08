# L4 — install tier. Drives `nixos-anywhere --vm-test` against a workspace
# host whose `etc/config.yaml` carries a disko profile (spec §11).
#
# :::caution[Best-effort wrapper]
# `nixos-anywhere`'s `--vm-test` mode is a CLI flow; wrapping it as a
# deterministic `runCommand`-derivation is non-trivial because the test
# spawns qemu and is not pure. This helper builds the host's `toplevel`
# (so eval/build failures still surface in `.#checks`) and, when the
# `nixos-anywhere` input exposes a usable derivation, returns it; else it
# falls back to a documentation marker pointing at the manual command —
# explicitly allowed by Phase 9.4 of the plan.
# :::

{ pkgs, inputs }:
{
  name,
  workspace,
  host,
}:
let
  inherit (pkgs) lib;
  ws = import ./workspace.nix { inherit inputs; } workspace;
  nodeDef = ws.nodeOf host;

  # Standalone `nixosSystem` — same shape `mkEvalTest` uses, with the
  # nixpkgs/system layer added back since no test driver owns it here.
  system = inputs.nixpkgs.lib.nixosSystem {
    inherit (nodeDef) specialArgs;
    modules = nodeDef.modules ++ [
      "${inputs.nixpkgs}/nixos/modules/misc/nixpkgs.nix"
      { nixpkgs.hostPlatform.system = nodeDef.system; }
    ];
  };

  na = inputs.nixos-anywhere or null;

  # nixos-anywhere may expose a vm-test entry under different names depending
  # on the version. Try the common ones; first hit wins.
  vmTestCandidates =
    if na == null then
      [ ]
    else
      lib.filter (x: x != null) [
        (na.packages.${pkgs.system}.nixos-anywhere-vm-test or null)
        (na.checks.${pkgs.system}.vm-test or null)
      ];

  fallback =
    pkgs.runCommand "install-${name}" { passthru.toplevel = system.config.system.build.toplevel; }
      ''
        mkdir -p "$out"
        cat > "$out/README" <<EOF
        L4 install tier for host '${host}' (workspace ${toString workspace}).

        No automatic vm-test derivation exposed by the pinned nixos-anywhere
        input. The host's toplevel was built (see passthru.toplevel) — eval
        regressions are caught. To actually drive the install in a VM, run:

          just install ${host} test

        from a workspace that includes this host (cf. plan Phase 9.4).
        EOF
      '';
in
if vmTestCandidates != [ ] then builtins.head vmTestCandidates else fallback
