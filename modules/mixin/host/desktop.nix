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
