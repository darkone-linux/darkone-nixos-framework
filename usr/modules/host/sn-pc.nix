{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.host.sn-pc;
in
{
  options = {
    darkone.host.sn-pc.enable = lib.mkEnableOption "SN workstations";
  };

  config = lib.mkIf cfg.enable {

    # Darkone modules for SN PCs
    darkone = {

      # Based on laptop framework profile
      host.desktop.enable = true;

      # Advanced user (developper / admin)
      theme.advanced.enable = true;
      theme.office.enable = true;
      #theme.teenager.enable = true;

      # Games activation / deactivation
      graphic.education.enableGames = false;

      # No email software
      graphic.office.enableEmail = false;

      # Virtualbox
      #graphic.virtualbox.enable = true;

      # Dev web
      service.httpd.enable = true;

      # Multimedia
      graphic.imagery.enable = true;
      graphic.video.enable = true;
      #graphic.music.enable = true;
    };

    networking.firewall = {
      enable = true;
      allowPing = true;
      allowedTCPPorts = [
        22
        80
      ];
      allowedUDPPorts = [
        2757 # STK (discovery)
        2759 # STK (game)
      ];
    };

    # NFS for homes
    #systemd.tmpfiles.rules = [ "d /mnt/home 0755 root root" ];
    environment.systemPackages = with pkgs; [ nfs-utils ];
    boot.initrd = {
      supportedFilesystems = [ "nfs" ];
      kernelModules = [ "nfs" ];
    };
    fileSystems."/mnt/home" = {
      device = "nixfarm:/export/home";
      fsType = "nfs";
      #options = [ "nfsvers=4.2" ];
    };
    security.wrappers."mount.nfs" = {
      setuid = true;
      owner = "root";
      group = "root";
      source = "${pkgs.nfs-utils.out}/bin/mount.nfs";
    };

    # Hardware additional settings
    hardware.bluetooth.enable = lib.mkForce false;
  };
}
