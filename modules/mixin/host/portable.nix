# Portable configuration for a bootable USB drive containing a NixOS machine from the local network.

{
  lib,
  config,
  dnfConfig,
  dnfLib,
  host,
  ...
}:
let
  cfg = config.darkone.host.portable;
  profileServicesArgs = {
    profileName = "portable";
    inherit host;
    inherit (dnfConfig) modules;
  };
in
{
  options = {
    darkone.host.portable.enable = lib.mkEnableOption "Portable host configuration for usb keys";
  };

  # TODO: specific boot options for usb keys
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Based on laptop configuration
        #darkone.host.laptop.enable = true;
        darkone.host.minimal.enable = true;

        # More hardware drivers
        darkone.system.hardware = {
          enable = true;
          enableIntel = true;
          enableAmd = true;
        };
        hardware.enableAllHardware = true;
      }

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
