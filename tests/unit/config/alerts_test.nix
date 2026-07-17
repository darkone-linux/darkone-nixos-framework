# Tests for config/alerts.nix (framework-wide alerting registry)
# Run with: nix-unit --flake .#libTests
{ dnfLib, lib }:
let
  inherit (dnfLib) checkSchema;

  alerts = import ../../../config/alerts.nix;

  # Shape of the registry: `ignoredUnits` is a list of distinct unit names.
  # A duplicate would be a silent no-op in the generated `name!~` alternation.
  schema = {
    type = "attrs";
    key.oneOf = [ "ignoredUnits" ];
    fields.ignoredUnits = {
      type = "listOfStrings";
      unique = true;
    };
  };

  # Full unit names only: the rule matches the `name` label exactly, so a bare
  # `mautrix-telegram` would silence nothing. `listOfStrings` cannot express a
  # per-element regex, hence the explicit filter.
  malformed = lib.filter (
    u: builtins.match "[a-zA-Z0-9@_.:-]+\\.[a-z]+" u == null
  ) alerts.ignoredUnits;
in
{

  # Registry shape: known key, distinct string entries.
  testSchemaValid = {
    expr = checkSchema schema alerts;
    expected = [ ];
  };

  # Every entry is a suffixed unit name (empty == all well-formed).
  testUnitNamesWellFormed = {
    expr = malformed;
    expected = [ ];
  };
}
