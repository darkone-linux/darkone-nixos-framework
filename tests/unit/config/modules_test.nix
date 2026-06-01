# Tests for config/modules.nix (framework module registry)
# Run with: nix-unit --flake .#libTests
{ dnfLib, lib }:
let
  modules = import ../../../config/modules.nix;

  # `../../..` is the dnf flake root (tests/unit/config/ → up 3); used to assert
  # that each module / profile name maps to a real source file.
  dnfRoot = ../../..;

  # Grammar of config/modules.nix. Each top-level key is a service module name;
  # its value describes opinionated defaults plus an optional activation tree.
  modulesSchema = {
    type = "attrs";

    # Every module name must have a matching service module file.
    key = {
      root = dnfRoot;
      fileExists = "modules/service/{{value}}.nix";
    };

    # Per-module entry.
    value = {
      type = "attrs";
      key.oneOf = [
        "reverseProxy"
        "uniquePerZone"
        "externalAccess"
        "description"
        "activation"
      ];
      fields.reverseProxy.type = "bool";
      fields.uniquePerZone.type = "bool";
      fields.externalAccess.type = "bool";
      fields.description.type = "string";
      fields.activation = {
        type = "attrs";
        key.oneOf = [ "profiles" ];
        fields.profiles = {
          type = "attrs";

          # Each profile name must map to a host mixin file.
          key = {
            root = dnfRoot;
            fileExists = "modules/mixin/host/{{value}}.nix";
          };
          value = {
            type = "attrs";
            key.oneOf = [ "triggers" ];
            fields.triggers = {
              type = "attrs";
              key.oneOf = [
                "always"
                "keys"
              ];

              # Unconditional activation actions for the profile (no dup).
              fields.always = {
                type = "listOfStrings";
                unique = true;
              };

              # Per user-key activation actions (no dup).
              fields.keys = {
                type = "attrs";
                value = {
                  type = "listOfStrings";
                  unique = true;
                };
              };
            };
          };
        };
      };
    };
  };

  # ----- cross-cutting: each trigger key belongs to a single module -----
  # `triggers.keys.<myKey>` activates a module when `host.services.<myKey>` is
  # set, so a given key must map to ONE module unambiguously. A key may repeat
  # across profiles of the same module (e.g. `idm` under gateway + hcs); only a
  # claim by two distinct modules is a conflict. (checkSchema is node-local and
  # cannot express this — hence a dedicated test.)
  triggerKeyOwners =
    let
      perModule = lib.mapAttrsToList (
        moduleName: cfg:
        let
          profiles = cfg.activation.profiles or { };
          keys = lib.concatMap (p: lib.attrNames (profiles.${p}.triggers.keys or { })) (
            lib.attrNames profiles
          );
        in
        map (key: { inherit key moduleName; }) (lib.unique keys)
      ) modules;
    in
    lib.groupBy (e: e.key) (lib.concatLists perModule);

  duplicateKeyViolations = lib.mapAttrsToList (
    key: entries:
    "trigger key \"${key}\" claimed by modules: ${
      lib.concatStringsSep ", " (map (e: e.moduleName) entries)
    }"
  ) (lib.filterAttrs (_: entries: lib.length entries > 1) triggerKeyOwners);
in
{

  # Full grammar + filesystem checks: zero violation == valid registry. Any new
  # module / profile / trigger added to modules.nix is validated by this test.
  testModulesMatchSchema = {
    expr = dnfLib.checkSchema modulesSchema modules;
    expected = [ ];
  };

  # No trigger key may be claimed by more than one module.
  testUniqueTriggerKeys = {
    expr = duplicateKeyViolations;
    expected = [ ];
  };
}
