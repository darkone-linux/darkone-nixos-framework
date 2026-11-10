# Tests for dnf/lib/networking.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let

  # Shape of the generated `zone.extraDnsmasqSettings`: native hosts, then a
  # visiting host whose MACs also hold an address of this zone.
  mockZone = {
    extraDnsmasqSettings.dhcp-host = [
      "02:00:00:00:00:01,10.0.1.2"
      "02:00:00:00:00:02,02:00:00:00:00:03,10.0.1.3"
      "02:00:00:00:00:04,10.0.1.20"
      "02:00:00:00:00:02,02:00:00:00:00:03,10.0.6.1"
    ];
  };
in
{

  # ----- extractReversePrefix -----

  # First two labels are swapped to form the PTR domain prefix.
  testReversePrefixClassC = {
    expr = dnfLib.extractReversePrefix "192.168.1.0";
    expected = "168.192";
  };
  testReversePrefixTenNet = {
    expr = dnfLib.extractReversePrefix "10.1.2.0";
    expected = "1.10";
  };

  # Only the first two labels matter, trailing ones are ignored.
  testReversePrefixIgnoresTail = {
    expr = dnfLib.extractReversePrefix "172.16.42.99";
    expected = "16.172";
  };

  # ----- getReservedMacs -----

  testReservedMacsSingle = {
    expr = dnfLib.getReservedMacs mockZone "10.0.1.2";
    expected = [ "02:00:00:00:00:01" ];
  };

  # Several MACs, in entry order; the visiting entry of the same MACs does
  # not leak in.
  testReservedMacsSeveral = {
    expr = dnfLib.getReservedMacs mockZone "10.0.1.3";
    expected = [
      "02:00:00:00:00:02"
      "02:00:00:00:00:03"
    ];
  };

  # Whole-field match: 10.0.1.2 must not pick the entry of 10.0.1.20.
  testReservedMacsExactIp = {
    expr = dnfLib.getReservedMacs mockZone "10.0.1.20";
    expected = [ "02:00:00:00:00:04" ];
  };

  testReservedMacsUnknownIp = {
    expr = dnfLib.getReservedMacs mockZone "10.0.1.99";
    expected = [ ];
  };

  # Global zone: no DHCP settings at all.
  testReservedMacsNoDhcp = {
    expr = dnfLib.getReservedMacs { } "203.0.113.1";
    expected = [ ];
  };
}
