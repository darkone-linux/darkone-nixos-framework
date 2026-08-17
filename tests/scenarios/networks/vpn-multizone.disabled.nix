# L3+ — multi-zone workspace with `coordination.enable = true`, exercising
# `mkVpnTest` on the `hcs` profile. The headscale service is declared by
# the `hcs` mixin but force-disabled by the test seam (spec §7); asserting
# it is inactive is the empirical seam check for the VPN tier.
#
# DISABLED (`.disabled.nix` suffix → no check is produced, cf. ../default.nix).
# Same root cause as network-dns: `mkVpnTest` wraps `mkNetworkTest`, which
# injects `host` via `_module.args` → infinite recursion.
#
# The workspace itself is NOT uncovered: `../eval-all.nix` still evaluates
# every host of `workspaces/vpn/configs/multizone` at the L1 tier. Only the L3
# boot-and-assert tier is missing.
#
# TODO: fix multi-nodes tests, cf. .specs/dnf/docs/todo-fix-tests-multi-noeuds.md
# Restore by dropping the `.disabled` infix and uncommenting the body below.

# { pkgs, inputs }:
# (import ../../lib/mkVpnTest.nix { inherit pkgs inputs; }) {
#   name = "vpn-multizone";
#   workspace = ../../workspaces/vpn/configs/multizone;
#   testScript = ''
#     start_all()
#     hcs.wait_for_unit("multi-user.target")
#     hcs.fail("systemctl is-active headscale")
#   '';
# }

# Never imported (the discovery skips `.disabled.nix`). Kept as a valid Nix
# expression so treefmt/statix/deadnix still cover the file, and loud rather
# than silent should the skip ever regress.
_: throw "tests/scenarios/networks/vpn-multizone is disabled and registers no check."
