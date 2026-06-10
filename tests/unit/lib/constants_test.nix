# Tests for dnf/lib/constants.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }: {
  testCaddyStoragePath = {
    expr = dnfLib.constants.caddyStorage;
    expected = "/var/lib/caddy/storage";
  };

  testGlobalZone = {
    expr = dnfLib.constants.globalZone;
    expected = "www";
  };

  testLanInterface = {
    expr = dnfLib.constants.lanInterface;
    expected = "lan0";
  };

  testVpnInterface = {
    expr = dnfLib.constants.vpnInterface;
    expected = "tailscale0";
  };
}
