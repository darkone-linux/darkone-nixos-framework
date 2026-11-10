# Portable configuration for a bootable USB drive containing a NixOS machine from the local network.

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

    # Based on the minimal configuration, not on the laptop one
    darkone.host.minimal.enable = true;

    # ANSSI machine category: a USB key is used as a workstation, and it
    # inherits `minimal`, which stays `base`.
    darkone.system.security.category = "client";

    # More hardware drivers
    darkone.system.hardware = {
      enable = true;
      enableIntel = true;
      enableAmd = true;
    };
    hardware.enableAllHardware = true;
  };
}
