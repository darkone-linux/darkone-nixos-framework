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
let

  # `triggers` of a `config/modules.nix` entry for one host profile.
  profileTriggers =
    profileName: moduleConfig: moduleConfig.activation.profiles.${profileName}.triggers or { };
in
{

  # `{ darkone.service.<module>.<opt> = true; }` for every option the profile
  # triggers on `host`. Never assigns `false`: module defaults still apply and
  # downstream `lib.mkForce` overrides stay valid.
  triggerProfileServices =
    {
      profileName,
      host,
      modules,
    }:
    let
      hostServices = host.services or { };

      # Above `mkDefault` (1000), below a plain definition (100).
      mkHigherDefault = lib.mkOverride 200;

      activateModule =
        moduleName: moduleConfig:
        let
          triggers = profileTriggers profileName moduleConfig;
          alwaysOpts = triggers.always or [ ];
          keyOpts = lib.flatten (
            lib.mapAttrsToList (key: opts: lib.optionals (builtins.hasAttr key hostServices) opts) (
              triggers.keys or { }
            )
          );
          allOpts = lib.unique (alwaysOpts ++ keyOpts);
        in
        if allOpts == [ ] then
          { }
        else
          { darkone.service.${moduleName} = lib.genAttrs allOpts (_: mkHigherDefault true); };
    in
    lib.foldl' lib.recursiveUpdate { } (lib.mapAttrsToList activateModule modules);

  # Assertions: no host declares two `host.services` keys activating the same
  # module in the profile (e.g. both `restic` and `backuped`).
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
          keys = builtins.attrNames ((profileTriggers profileName moduleConfig).keys or { });
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
