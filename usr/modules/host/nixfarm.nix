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

    # Server for advanced user
    darkone = {
      host.server.enable = true;
      theme.advanced.enable = true;
    };

    # NFS shares
    services.nfs.server.enable = true;
    services.nfs.server.exports = ''
      /export/homes 192.168.11.0/24(rw,sync,insecure,no_subtree_check,fsid=homes)
    '';
    networking.firewall.allowedTCPPorts = [ 2049 ]; # NFSv4

    # AI
    services.ollama.enable = true;

    # Hardware additional settings
    hardware.bluetooth.enable = lib.mkForce false;
  };
}
