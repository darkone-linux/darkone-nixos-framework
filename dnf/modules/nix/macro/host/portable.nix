# Portable configuration for usb keys.

{ lib, config, ... }:
let
  cfg = config.darkone.host.portable;
in
{
  options = {
    darkone.host.portable.enable = lib.mkEnableOption "Portable host configuration for usb keys";
  };

  # TODO: specific boot options for usb keys
  config = lib.mkIf cfg.enable {

    # Based on laptop configuration
    darkone.host.laptop.enable = lib.mkForce true;

    # More hardware drivers
    darkone.system.hardware = {
      enable = true;
      enableIntel = true;
      enableAmd = true;
    };
    hardware.enableAllHardware = true;
  };
}
