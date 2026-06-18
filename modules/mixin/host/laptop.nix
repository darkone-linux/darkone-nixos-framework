# Desktop config + laptop specific tools & configuration.

{
  lib,
  pkgs,
  config,
  dnfConfig,
  dnfLib,
  host,
  ...
}:
let
  cfg = config.darkone.host.laptop;
  profileServicesArgs = {
    profileName = "laptop";
    inherit host;
    inherit (dnfConfig) modules;
  };
in
{
  options = {
    darkone.host.laptop.enable = lib.mkEnableOption "Laptop optimized host configuration";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Based on desktop configuration
        darkone.host.desktop.enable = lib.mkDefault true;

        # Sensors management (WIP)
        boot.kernelModules = [ "coretemp" ];
        environment.systemPackages = with pkgs; [ lm_sensors ];

        # suspend, sleep, hibernates are deactivated by default: activation
        darkone.system.core.enableAutoSuspend = lib.mkDefault true;

        # Blank the screen earlier on laptops (battery saving): 15 min
        darkone.graphic.gnome.screenBlankDelay = lib.mkDefault 900;

        # Temperature management daemon
        services.thermald.enable = lib.mkDefault true;
      }

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
