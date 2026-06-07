# Tests for dnf/lib/networking.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
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
}
