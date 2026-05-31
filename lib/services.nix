# Service activation helpers for DNF host-profile mixins.
#
# Reads `activation.profiles.<profile>.triggers` from `dnfConfig.modules`
# and emits NixOS config fragments, decoupling activation logic from
# individual mixin modules.
#
# :::tip[Adding a new service]
# Add an `activation` entry in `config/modules.nix`; no mixin edit needed.
# :::
#
# :::note[Trigger semantics]
# - `triggers.always`: unconditionally activates each listed option.
# - `triggers.keys.<key>`: activates if `<key>` is present in `host.services`;
#   multiple keys can map to the same module (e.g. `restic` and `backuped`),
#   but only one may be declared per host — enforced by `mkHostProfileServicesAssertions`.
# :::

{ lib }:
{
  # Build a plain attrset activating `darkone.service.*` options for a profile.
  #
  # Returns `{ darkone.service.<module> = { <opt> = true; ... }; ... }`.
  # Only emits `true` — never assigns `false`, so module defaults apply and
  # downstream `lib.mkForce` overrides remain valid.
  triggerProfileServices =
    {
      profileName,
      host,
      modules,
    }:
    let
      hostServices = host.services or { };

      activateModule =
        moduleName: moduleConfig:
        let
          triggers = ((moduleConfig.activation or { }).profiles.${profileName} or { }).triggers or { };
          alwaysOpts = triggers.always or [ ];
          keyOpts = lib.flatten (
            lib.mapAttrsToList (key: opts: lib.optionals (builtins.hasAttr key hostServices) opts) (
              triggers.keys or { }
            )
          );
          allOpts = lib.unique (alwaysOpts ++ keyOpts);
        in
        if allOpts == [ ] then { } else { darkone.service.${moduleName} = lib.genAttrs allOpts (_: true); };
    in
    lib.foldl' lib.recursiveUpdate { } (lib.mapAttrsToList activateModule modules);

  # Build NixOS assertions ensuring no host declares two `host.services` keys
  # that both activate the same module in the given profile.
  #
  # Example: `restic` and `backuped` both activate the `restic` module —
  # declaring both in `host.services` is an error.
  mkHostProfileServicesAssertions =
    {
      profileName,
      host,
      modules,
    }:
    let
      hostServices = host.services or { };
    in
    lib.flatten (
      lib.mapAttrsToList (
        moduleName: moduleConfig:
        let
          triggers = ((moduleConfig.activation or { }).profiles.${profileName} or { }).triggers or { };
          keys = builtins.attrNames (triggers.keys or { });
          matchingKeys = builtins.filter (key: builtins.hasAttr key hostServices) keys;
        in

        # Only relevant when a module exposes several possible trigger keys.
        lib.optional (builtins.length keys > 1) {
          assertion = builtins.length matchingKeys <= 1;
          message =
            "Host '${host.hostname}': module '${moduleName}' triggered by "
            + "multiple keys in profile '${profileName}': "
            + lib.concatStringsSep ", " matchingKeys;
        }
      ) modules
    );
}
