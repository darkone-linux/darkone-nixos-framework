# Tests for dnf/lib/config-schema.nix (the checkSchema engine)
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  inherit (dnfLib) checkSchema;

  # Reusable schema: an attrs limited to "ports", values are unique ports.
  portsSchema = {
    type = "attrs";
    exactKeys = [ "ports" ];
    fields.ports = {
      type = "attrs";
      valueType = "port";
      uniqueValues = true;
    };
  };
in
{

  # ----- happy path -----
  testValidMinimal = {
    expr = checkSchema portsSchema {
      ports = {
        a = 8444;
        b = 9000;
      };
    };
    expected = [ ];
  };

  testValidEmptyPorts = {
    expr = checkSchema portsSchema { ports = { }; };
    expected = [ ];
  };

  # ----- exactKeys: unknown top-level key rejected -----
  testUnknownKey = {
    expr = checkSchema portsSchema {
      ports = { };
      foo = { };
    };
    expected = [ "<root>: unknown key \"foo\" (allowed: ports)" ];
  };

  # ----- valueType: wrong leaf type -----
  testWrongType = {
    expr = checkSchema portsSchema {
      ports = {
        a = "8444";
      };
    };
    expected = [ "ports.a: must be an internal port (int in 1024-65535)" ];
  };

  # ----- range: below 1024 and above 65535 rejected, bounds accepted -----
  testPortTooLow = {
    expr = checkSchema portsSchema {
      ports = {
        a = 80;
      };
    };
    expected = [ "ports.a: must be an internal port (int in 1024-65535)" ];
  };

  testPortTooHigh = {
    expr = checkSchema portsSchema {
      ports = {
        a = 70000;
      };
    };
    expected = [ "ports.a: must be an internal port (int in 1024-65535)" ];
  };

  testPortBounds = {
    expr = checkSchema portsSchema {
      ports = {
        lo = 1024;
        hi = 65535;
      };
    };
    expected = [ ];
  };

  # ----- uniqueValues: duplicate detected, distinct values pass -----
  testDuplicateValues = {
    expr = checkSchema portsSchema {
      ports = {
        a = 8444;
        b = 8444;
      };
    };
    expected = [ "ports: values must be unique" ];
  };

  # ----- nested recursion: violation path is fully qualified -----
  testNestedPath = {
    expr = checkSchema {
      type = "attrs";
      fields.outer = {
        type = "attrs";
        fields.inner = {
          type = "attrs";
          valueType = "int";
        };
      };
    } { outer.inner.x = "nope"; };
    expected = [ "outer.inner.x: must be an int" ];
  };

  # ----- non-attrs where attrs expected -----
  testNotAnAttrs = {
    expr = checkSchema portsSchema { ports = 42; };
    expected = [ "ports: must be an attrset" ];
  };
}
