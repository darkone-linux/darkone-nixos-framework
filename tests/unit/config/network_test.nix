# Tests for config/network.nix (framework-wide port registry)
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  network = import ../../../config/network.nix;

  # Grammar of config/network.nix. Extend `key.oneOf`/`fields` as the registry
  # grows (e.g. an `addresses` section); the engine and this test stay put.
  networkSchema = {
    type = "attrs";

    # Only "ports" is admitted for now.
    key.oneOf = [ "ports" ];
    fields.ports = {
      type = "attrs";

      # Port names: alphanumeric identifiers.
      key.regex = "[a-zA-Z0-9]+";

      # Each value is a unique internal service port.
      value = {
        type = "int";
        min = 1024;
        max = 65535;
        unique = true;
      };
    };
  };
in
{

  # Full grammar + constraints check: zero violation == valid file. Any new
  # port added to network.nix is validated automatically by this single test.
  testNetworkMatchesSchema = {
    expr = dnfLib.checkSchema networkSchema network;
    expected = [ ];
  };
}
