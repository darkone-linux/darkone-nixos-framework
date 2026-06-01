# Tests for config/network.nix (framework-wide port registry)
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  network = import ../../../config/network.nix;

  # Grammar of config/network.nix. Extend `exactKeys`/`fields` as the registry
  # grows (e.g. an `addresses` section); the engine and these tests stay put.
  networkSchema = {
    type = "attrs";

    # Only "ports" is admitted for now.
    exactKeys = [ "ports" ];
    fields.ports = {
      type = "attrs";

      # Each value is an internal service port (int 1024-65535)...
      valueType = "port";

      # ...and no two services may share the same port.
      uniqueValues = true;
    };
  };
in
{

  # Full grammar + constraints check: zero violation == valid file.
  testNetworkMatchesSchema = {
    expr = dnfLib.checkSchema networkSchema network;
    expected = [ ];
  };

  # Readable cross-check: top-level shape is exactly { ports = ...; }.
  testOnlyPortsKey = {
    expr = builtins.attrNames network;
    expected = [ "ports" ];
  };

  # Readable cross-check: a known port is registered as an int.
  testKanidmPortIsInt = {
    expr = builtins.isInt network.ports.kanidmReplPort;
    expected = true;
  };
}
