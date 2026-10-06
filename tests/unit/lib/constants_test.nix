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

  testTextfileCollectorDir = {
    expr = dnfLib.constants.textfileCollectorDir;
    expected = "/var/lib/node-exporter-textfile";
  };

  testRoamingDomain = {
    expr = dnfLib.constants.roamingDomain;
    expected = "dnf.internal";
  };

  testNixCacheRoamingFqdn = {
    expr = dnfLib.constants.nixCacheRoamingFqdn;
    expected = "nix-cache.dnf.internal";
  };

  testHarmoniaRoamingFqdn = {
    expr = dnfLib.constants.harmoniaRoamingFqdn;
    expected = "harmonia.dnf.internal";
  };

  testTailnetDomain = {
    expr = dnfLib.constants.tailnetDomain;
    expected = "tailnet.internal";
  };

  testMagicDnsAddress = {
    expr = dnfLib.constants.magicDnsAddress;
    expected = "100.100.100.100";
  };

  # headscale's default `prefixes.v4`.
  testTailnetIpv4Cidr = {
    expr = dnfLib.constants.tailnetIpv4Cidr;
    expected = "100.64.0.0/10";
  };

  testInternetProbeTargets = {
    expr = dnfLib.constants.internetProbeTargets;
    expected = [
      "1.1.1.1"
      "9.9.9.9"
    ];
  };
}
