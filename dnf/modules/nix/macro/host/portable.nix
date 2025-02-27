# Portable configuration for usb keys (wip).

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
  };
}
