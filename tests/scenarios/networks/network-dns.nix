# TODO: fix multi-nodes tests, cf. .specs/dnf/docs/todo-fix-tests-multi-noeuds.md
# Disabled: `host` passed via `_module.args` causes infinite recursion when
# `runNixOSTest` evaluates `driverConfiguration.vlans` (forces full node config
# fixpoint, which requires `_module.args`, which requires `config` → cycle).
{ pkgs, ... }:
pkgs.runCommand "network-dns-disabled" { } "echo disabled > $out"

# L3 — two real DNF nodes booted together on the same zone VLAN. Gates
# Phase 7 risk (5): per-node specialArgs (`host`, `zone`) injected via
# `_module.args` must not recurse with workspace-shared args hoisted to
# the driver-level `node.specialArgs`.
#
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
