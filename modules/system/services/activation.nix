# Service activation by host profile: what `config/modules.nix` triggers.

{
  lib,
  config,
  dnfConfig,
  dnfLib,
  host,
  ...
}:
let
  inherit (dnfConfig) modules;

  # Profiles named by at least one registry entry; the others trigger nothing.
  profiles = lib.unique (
    lib.concatMap (module: lib.attrNames (module.activation.profiles or { })) (lib.attrValues modules)
  );

  argsOf = profileName: { inherit profileName host modules; };

  # A profile enabled through another one (`laptop` → `desktop` → `minimal`)
  # gets the triggers of each of them.
  activate =
    profileName:
    lib.mkIf config.darkone.host.${profileName}.enable (
      lib.mkMerge [
        (dnfLib.triggerProfileServices (argsOf profileName))
        { assertions = dnfLib.mkHostProfileServicesAssertions (argsOf profileName); }
      ]
    );
in
{
  config = lib.mkMerge (map activate profiles);
}
