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
      graphic.virtualbox.enable = true;

      # Dev web
      service.httpd.enable = true;

      # Multimedia
      graphic.imagery.enable = true;
      graphic.video.enable = true;
      #graphic.music.enable = true;
    };

    # Partition de boot limitée par le partitionnement windows
    boot.loader.systemd-boot.configurationLimit = 2;
    boot.loader.timeout = 15;
    networking.interfaces.enp2s0.wakeOnLan.enable = true;

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

    # TODO: TMPFS pour les caches

    # NFS for homes
    #systemd.tmpfiles.rules = [ "d /mnt/home 0755 root root" ];
    environment.systemPackages = with pkgs; [ nfs-utils ];
    boot.initrd = {
      supportedFilesystems = [ "nfs" ];
      kernelModules = [ "nfs" ];
    };
    fileSystems."/mnt/home" = {
      device = "nixfarm:/home";
      fsType = "nfs";
      options = [
        "nfsvers=4.2"
        "rsize=65536"
        "wsize=65536"
        "hard"
        "timeo=600"
        "retrans=2"
      ];
    };
    security.wrappers."mount.nfs" = {
      setuid = true;
      owner = "root";
      group = "root";
      source = "${pkgs.nfs-utils.out}/bin/mount.nfs";
    };

    # TODO: factorize with nixfarm
    services.nfs.settings = {
      nfsd.udp = false;
      nfsd.vers3 = false;
      nfsd.vers4 = true;
      nfsd."vers4.0" = false;
      nfsd."vers4.1" = false;
      nfsd."vers4.2" = true;
    };

    # Hardware additional settings
    hardware.bluetooth.enable = lib.mkForce false;

    # SN-PC state version (do not touch or update)
    system.stateVersion = "25.05";
  };
}
