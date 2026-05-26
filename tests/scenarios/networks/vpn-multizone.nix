# L3+ — multi-zone workspace with `coordination.enable = true`, exercising
# `mkVpnTest` on the `hcs` profile. The headscale service is declared by
# the `hcs` mixin but force-disabled by the test seam (spec §7); asserting
# it is inactive is the empirical seam check for the VPN tier.

{ pkgs, inputs }:
(import ../../lib/mkVpnTest.nix { inherit pkgs inputs; }) {
  name = "vpn-multizone";
  workspace = ../../workspaces/vpn/configs/multizone;
  testScript = ''
    start_all()
    hcs.wait_for_unit("multi-user.target")
    hcs.fail("systemctl is-active headscale")
  '';
}
