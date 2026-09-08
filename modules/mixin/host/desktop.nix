# A full desktop configuration with gnome, multimedia and office tools.

{
  lib,
  config,
  dnfConfig,
  dnfLib,
  host,
  ...
}:
let
  cfg = config.darkone.host.desktop;
  profileServicesArgs = {
    profileName = "desktop";
    inherit host;
    inherit (dnfConfig) modules;
  };
in
{
  options = {
    darkone.host.desktop.enable = lib.mkEnableOption "Desktop optimized host configuration";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Load minimal configuration
        darkone.host.minimal.enable = lib.mkDefault true;

        # ANSSI machine category, inherited by `laptop`, `umi` and the
        # consumer-side admin profiles — never restated there, two definitions
        # of different values on the same option conflict. No rule is `client`
        # before the `reinforced` tier (C3, USBGuard): this is a statement of
        # what the host is, not a change of behaviour today.
        darkone.system.security.category = "client";

        # System additional features
        darkone.system.core = {
          enableFstrim = lib.mkDefault true;
          enableBoost = lib.mkDefault false;
        };

        # Enable gnome
        darkone.graphic.gnome.enable = lib.mkDefault true;
      }

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
