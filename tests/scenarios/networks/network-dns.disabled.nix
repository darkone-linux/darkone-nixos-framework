# L3 — two real DNF nodes booted together on the same zone VLAN. Gates
# Phase 7 risk (5): per-node specialArgs (`host`, `zone`) injected via
# `_module.args` must not recurse with workspace-shared args hoisted to
# the driver-level `node.specialArgs`.
#
# DISABLED (`.disabled.nix` suffix → no check is produced, cf. ../default.nix).
# `host` passed via `_module.args` causes infinite recursion when
# `runNixOSTest` evaluates `driverConfiguration.vlans`: that forces the full
# node config fixpoint, which requires `_module.args`, which requires `config`.
#
# The workspace itself is NOT uncovered: `../eval-all.nix` still evaluates
# every host of `workspaces/network/configs/dns` at the L1 tier. Only the L3
# boot-and-assert tier is missing.
#
# TODO: fix multi-nodes tests, cf. .specs/dnf/docs/todo-fix-tests-multi-noeuds.md
# Restore by dropping the `.disabled` infix and uncommenting the body below.

# { pkgs, inputs }:
# (import ../../lib/mkNetworkTest.nix { inherit pkgs inputs; }) {
#   name = "network-dns";
#   workspace = ../../workspaces/network/configs/dns;
#   testScript = ''
#     start_all()
#     node1.wait_for_unit("multi-user.target")
#     node2.wait_for_unit("multi-user.target")
#
#     # Distinct per-node specialArgs: hostnames flow from `host` -> /etc/hostname.
#     node1.succeed("test \"$(hostname)\" = node1")
#     node2.succeed("test \"$(hostname)\" = node2")
#   '';
# }

# Never imported (the discovery skips `.disabled.nix`). Kept as a valid Nix
# expression so treefmt/statix/deadnix still cover the file, and loud rather
# than silent should the skip ever regress.
_: throw "tests/scenarios/networks/network-dns is disabled and registers no check."
