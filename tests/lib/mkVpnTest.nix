# L3+ — multi-zone simulation. Thin alias over `mkNetworkTest`: same
# mechanics (per-node specialArgs hoisted as in `mkNetworkTest.nix`, VLANs
# from `vlans.nix`), distinct name so the spec's `vpn-*` correspondence
# (§4) stays explicit and the helper can grow VPN-specific knobs later
# (headscale-stub assertions, mesh fixtures) without touching the network
# tier.
#
# Aim: use.

{ pkgs, inputs }:
{
  name,
  workspace,
  hosts ? null,
  testScript,
}:
(import ./mkNetworkTest.nix { inherit pkgs inputs; }) {
  inherit
    name
    workspace
    hosts
    testScript
    ;
}
