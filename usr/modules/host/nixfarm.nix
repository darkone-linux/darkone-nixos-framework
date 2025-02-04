{ lib, config, ... }:
let
  cfg = config.darkone.host.nixfarm;
in
{
  options = {
    darkone.host.nixfarm.enable = lib.mkEnableOption "SN NixFarm Calculator";
  };

  config = lib.mkIf cfg.enable {

    # GRUB bootloader instead of systemd-boot
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
    boot.loader.grub.enable = true;
    boot.loader.grub.device = "/dev/sda";

    darkone = {
      host.server.enable = true;
      theme.advanced.enable = true;
    };

    # AI
    services.ollama.enable = true;

    # Hardware additional settings
    hardware.bluetooth.enable = lib.mkForce false;
  };
}
