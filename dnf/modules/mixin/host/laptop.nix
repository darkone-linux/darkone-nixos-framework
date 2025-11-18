# Desktop config + laptop specific tools & configuration.

{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.darkone.host.laptop;
in
{
  options = {
    darkone.host.laptop.enable = lib.mkEnableOption "Laptop optimized host configuration";
  };

  config = lib.mkIf cfg.enable {

    # Based on desktop configuration
    darkone.host.desktop.enable = lib.mkDefault true;

    # Several printing drivers
    darkone.service.printing.loadAll = lib.mkDefault true;

    # Sensors management (WIP)
    boot.kernelModules = [ "coretemp" ];
    environment.systemPackages = with pkgs; [ lm_sensors ];

    # suspend, sleep, hibernates are deactivated by default: activation
    darkone.system.core.enableAutoSuspend = lib.mkDefault true;

    # Temperature management daemon
    services.thermald.enable = true;
  };
}
