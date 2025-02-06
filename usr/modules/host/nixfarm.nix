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
    services.nfs.server = {
      enable = true;
      #exports = "/export/home 192.168.11.0/24(rw,async,insecure,no_subtree_check,no_root_squash,fsid=0)";
      exports = "/export/home 192.168.11.0/24(rw,async,insecure,no_subtree_check,no_root_squash,fsid=0)";
      createMountPoints = true;

      # TODO: pas utile normalement avec nfsv4...
      lockdPort = 4001;
      mountdPort = 4002;
      statdPort = 4000;
      extraNfsdConfig = '''';
    };
    #networking.firewall.allowedTCPPorts = [ 2049 ]; # NFSv4
    # TODO: avec nfsv4 il faut en théorie que ça fonctionne sans toutes ces configurations...
    networking.firewall = {
      enable = true;
      # for NFSv3; view with `rpcinfo -p`
      allowedTCPPorts = [
        111
        2049
        4000
        4001
        4002
        20048
      ];
      allowedUDPPorts = [
        111
        2049
        4000
        4001
        4002
        20048
      ];
    };
    services.rpcbind.enable = true;

    # AI
    services.ollama.enable = true;

    # Hardware additional settings
    hardware.bluetooth.enable = lib.mkForce false;
  };
}
