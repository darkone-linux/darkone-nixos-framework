# Tests for dnf/lib/config-schema.nix (the checkSchema engine)
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  inherit (dnfLib) checkSchema;

  # Reusable attrs schema: keys are alphanumeric, values are unique ports.
  portsSchema = {
    type = "attrs";
    key.regex = "[a-zA-Z0-9]+";
    value = {
      type = "int";
      min = 1024;
      max = 65535;
      unique = true;
    };
  };

  # `../../..` is the dnf flake root (tests/unit/lib/ → up 3).
  dnfRoot = ../../..;
in
{

  # ----- happy path -----
  testValidPorts = {
    expr = checkSchema portsSchema {
      a = 8444;
      b = 9000;
    };
    expected = [ ];
  };

  testValidEmpty = {
    expr = checkSchema portsSchema { };
    expected = [ ];
  };

  # ----- key.oneOf -----
  testKeyOneOfReject = {
    expr = checkSchema {
      type = "attrs";
      key.oneOf = [ "ports" ];
    } { foo = 1; };
    expected = [ "<root>: key \"foo\" not allowed (oneOf: ports)" ];
  };

  # ----- key.regex -----
  testKeyRegexReject = {
    expr = checkSchema portsSchema { "bad-key" = 8444; };
    expected = [ "<root>: key \"bad-key\" does not match regex \"[a-zA-Z0-9]+\"" ];
  };

  # ----- key.fileExists (real filesystem, dnf root) -----
  testKeyFileExistsOk = {
    expr = checkSchema {
      type = "attrs";
      key = {
        root = dnfRoot;
        fileExists = "{{value}}.nix";
      };
      value.type = "bool";
    } { flake = true; };
    expected = [ ];
  };

  testKeyFileExistsMissing = {
    expr = checkSchema {
      type = "attrs";
      key = {
        root = dnfRoot;
        fileExists = "{{value}}.nix";
      };
      value.type = "bool";
    } { does-not-exist = true; };
    expected = [ "<root>: key \"does-not-exist\": expected file \"does-not-exist.nix\" not found" ];
  };

  # ----- int min/max (inclusive bounds) -----
  testIntBoundsOk = {
    expr = checkSchema portsSchema {
      lo = 1024;
      hi = 65535;
    };
    expected = [ ];
  };

  testIntTooLow = {
    expr = checkSchema portsSchema { a = 80; };
    expected = [ "a: must be >= 1024" ];
  };

  testIntTooHigh = {
    expr = checkSchema portsSchema { a = 70000; };
    expected = [ "a: must be <= 65535" ];
  };

  testIntWrongType = {
    expr = checkSchema portsSchema { a = "8444"; };
    expected = [ "a: must be an int" ];
  };

  # ----- string regex + oneOf -----
  testStringRegexReject = {
    expr = checkSchema {
      type = "string";
      regex = "[a-z]+";
    } "Bad1";
    expected = [ "<root>: must match regex \"[a-z]+\"" ];
  };

  testStringOneOfReject = {
    expr = checkSchema {
      type = "string";
      oneOf = [
        "red"
        "green"
      ];
    } "blue";
    expected = [ "<root>: must be one of red, green" ];
  };

  testStringOneOfOk = {
    expr = checkSchema {
      type = "string";
      oneOf = [
        "red"
        "green"
      ];
    } "green";
    expected = [ ];
  };

  # ----- bool -----
  testBoolReject = {
    expr = checkSchema { type = "bool"; } "true";
    expected = [ "<root>: must be a bool" ];
  };

  # ----- listOfStrings + unique -----
  testListOfStringsOk = {
    expr = checkSchema { type = "listOfStrings"; } [
      "a"
      "b"
    ];
    expected = [ ];
  };

  testListOfStringsReject = {
    expr = checkSchema { type = "listOfStrings"; } [
      "a"
      2
    ];
    expected = [ "<root>: must be a list of strings" ];
  };

  testListUniqueReject = {
    expr =
      checkSchema
        {
          type = "listOfStrings";
          unique = true;
        }
        [
          "a"
          "a"
        ];
    expected = [ "<root>: list elements must be unique" ];
  };

  # ----- value.unique across a map -----
  testValueUniqueReject = {
    expr = checkSchema portsSchema {
      a = 8444;
      b = 8444;
    };
    expected = [ "<root>: values must be unique" ];
  };

  # ----- nested recursion: fully-qualified path -----
  testNestedPath = {
    expr = checkSchema {
      type = "attrs";
      fields.outer = {
        type = "attrs";
        fields.inner.type = "int";
      };
    } { outer.inner = "nope"; };
    expected = [ "outer.inner: must be an int" ];
  };

  # ----- non-attrs where attrs expected -----
  testNotAnAttrs = {
    expr = checkSchema portsSchema 42;
    expected = [ "<root>: must be an attrset" ];
  };
}
