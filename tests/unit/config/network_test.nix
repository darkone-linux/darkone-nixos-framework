# Tests for config/network.nix (framework-wide port registry)
# Run with: nix-unit --flake .#libTests
{ dnfLib, lib }:
let
  inherit (dnfLib) checkSchema;

  ports = (import ../../../config/network.nix).ports;

  # Named DNF ports (everything but the `reserved` denylist).
  named = builtins.removeAttrs ports [ "reserved" ];
  reserved = ports.reserved;

  # Shape of the named map: alphanumeric keys, values are unique ints in the
  # 1024..65535 range. Any new `ports.<key>` is validated by this alone.
  namedSchema = {
    type = "attrs";
    key.regex = "[a-zA-Z0-9]+";
    value = {
      type = "int";
      min = 1024;
      max = 65535;
      unique = true;
    };
  };

  # Reserved entries must also be ints inside the valid port range.
  reservedOutOfRange = lib.filter (p: !(builtins.isInt p) || p < 1024 || p > 65535) reserved;

  # The whole point of the registry: every port (named value or reserved entry)
  # must be globally distinct, so two services can never silently collide.
  allPorts = builtins.attrValues named ++ reserved;
  duplicates = lib.unique (lib.filter (p: lib.count (q: q == p) allPorts > 1) allPorts);
in
{

  # Named ports: shape, bounds and uniqueness among themselves.
  testNamedPortsValid = {
    expr = checkSchema namedSchema named;
    expected = [ ];
  };

  # Reserved ports: ints in range.
  testReservedInRange = {
    expr = reservedOutOfRange;
    expected = [ ];
  };

  # Global uniqueness across named ports and reserved ports (empty == no clash).
  testNoPortCollision = {
    expr = duplicates;
    expected = [ ];
  };
}
