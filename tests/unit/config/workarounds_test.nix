# Tests for config/workarounds.nix (temporary workarounds registry)
# Run with: nix-unit --flake .#libTests
{ dnfLib, lib }:
let
  workarounds = import ../../../config/workarounds.nix;
  flakeInputs = lib.attrNames (import ../../../flake.nix).inputs;

  # `../../..` is the dnf flake root (tests/unit/config/ → up 3).
  dnfRoot = ../../..;

  required = [
    "kind"
    "files"
    "reason"
    "dropWhen"
    "since"
  ];

  schema = {
    type = "attrs";
    key.regex = "[a-z0-9-]+";
    value = {
      type = "attrs";
      key.oneOf = required ++ [
        "upstream"
        "package"
        "inputs"
      ];
      fields = {
        kind = {
          type = "string";
          oneOf = [
            "overlay"
            "backport"
            "pin"
            "inline"
            "insecure"
          ];
        };
        files = {
          type = "listOfStrings";
          unique = true;
        };
        reason.type = "string";
        dropWhen.type = "string";
        since = {
          type = "string";
          regex = "[0-9]{4}-[0-9]{2}-[0-9]{2}";
        };
        upstream = {
          type = "string";
          regex = "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+";
        };
        package = {
          type = "string";
          regex = "[A-Za-z0-9_+-]+(\\.[A-Za-z0-9_+-]+)*";
        };
        inputs = {
          type = "listOfStrings";
          unique = true;
        };
      };
    };
  };

  entries = lib.attrValues workarounds;
  registeredFiles = lib.concatMap (e: e.files) entries;
  registeredInputs = lib.concatMap (e: e.inputs or [ ]) entries;

  missingFields = lib.concatLists (
    lib.mapAttrsToList (
      id: e: map (f: "${id}: missing `${f}`") (lib.filter (f: !(e ? ${f})) required)
    ) workarounds
  );

  # `.nix` files of a framework directory, as dnf-root-relative paths.
  nixFilesOf =
    dir:
    map (f: "${dir}/${f}") (
      lib.filter (lib.hasSuffix ".nix") (lib.attrNames (builtins.readDir (dnfRoot + "/${dir}")))
    );

  # Overlays that are no workaround: packages from a third-party flake.
  permanentOverlays = [
    "lib/overlays/claude-code.nix"
    "lib/overlays/talon.nix"
  ];

  # `nixpkgs-*` inputs besides the release channel exist for a workaround.
  workaroundInputs = lib.filter (i: lib.hasPrefix "nixpkgs-" i && i != "nixpkgs-stable") flakeInputs;
in
{

  # Registry shape: known fields only, typed values.
  testSchemaValid = {
    expr = dnfLib.checkSchema schema workarounds;
    expected = [ ];
  };

  testRequiredFields = {
    expr = missingFields;
    expected = [ ];
  };

  # A dropped workaround takes its entry along.
  testFilesExist = {
    expr = lib.filter (f: !builtins.pathExists (dnfRoot + "/${f}")) registeredFiles;
    expected = [ ];
  };

  testInputsExist = {
    expr = lib.filter (i: !(lib.elem i flakeInputs)) registeredInputs;
    expected = [ ];
  };

  # A new overlay is either registered or declared permanent above.
  testOverlaysRegistered = {
    expr = lib.filter (f: !(lib.elem f (registeredFiles ++ permanentOverlays))) (
      nixFilesOf "lib/overlays"
    );
    expected = [ ];
  };

  testBackportsRegistered = {
    expr = lib.filter (f: !(lib.elem f registeredFiles)) (nixFilesOf "backports/nixos");
    expected = [ ];
  };

  testNixpkgsInputsRegistered = {
    expr = lib.filter (i: !(lib.elem i registeredInputs)) workaroundInputs;
    expected = [ ];
  };
}
