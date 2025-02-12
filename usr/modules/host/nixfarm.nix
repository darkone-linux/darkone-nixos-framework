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
    services.nfs = {
      settings = {
        nfsd.udp = false;
        nfsd.vers3 = false;
        nfsd.vers4 = true;
        nfsd."vers4.0" = false;
        nfsd."vers4.1" = false;
        nfsd."vers4.2" = true;
      };
      server = {
        enable = true;
        exports = ''
          /export 192.168.11.0/24(rw,insecure,no_subtree_check,fsid=0,sync)
          /export/home 192.168.11.0/24(rw,nohide,async,insecure,no_subtree_check,no_root_squash,fsid=0,no_wdelay)
        '';
        createMountPoints = true;
      };
    };
    networking.firewall.allowedTCPPorts = [ 2049 ]; # NFSv4

    # Gateway for the last room network
    networking.interfaces.enp3s0f0.useDHCP = true; # Interface connected to 192.168.11.*
    networking.interfaces.enp3s0f1.ipv4.addresses = [
      {
        address = "192.168.10.1";
        prefixLength = 24;
      }
    ]; # Interface for the network 192.168.10.*
    networking.firewall.extraCommands = ''
      iptables -t nat -A POSTROUTING -s 192.168.10.0/24 -o enp3s0f0 -j MASQUERADE
      iptables -A INPUT -i enp3s0f1 -j ACCEPT
    '';
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

    # AI
    services.ollama.enable = true;

    # Hardware additional settings
    hardware.bluetooth.enable = lib.mkForce false;
  };
}
