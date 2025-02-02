{ lib, config, ... }:
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
      theme.teenager.enable = true;

      # Games activation / deactivation
      graphic.education.enableGames = false;

      # No email software
      graphic.office.enableEmail = false;

      # Virtualbox
      graphic.virtualbox.enable = true;

      # Multimedia
      graphic.imagery.enable = true;
      graphic.video.enable = true;
      #graphic.music.enable = true;
    };

    # Hardware additional settings
    hardware.bluetooth.enable = lib.mkForce false;

    # Hardware configuration is identical for all PCs
    #imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
    boot.initrd.availableKernelModules = [
      "ata_piix"
      "uhci_hcd"
      "sr_mod"
      "xen_blkfront"
    ];
    boot.initrd.kernelModules = [ ];
    boot.kernelModules = [ ];
    boot.extraModulePackages = [ ];
    fileSystems."/" = {
      device = "/dev/disk/by-uuid/5b32fe4f-d1fe-44bb-907b-a5b8e4ed7621";
      fsType = "ext4";
    };
    fileSystems."/boot" = {
      device = "/dev/disk/by-uuid/5719-4F30";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
    swapDevices = [ { device = "/dev/disk/by-uuid/9d3f5bf2-bba5-437d-adc4-ac22ebe3f026"; } ];
    networking.useDHCP = lib.mkDefault true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # Host specific state version
    system.stateVersion = "24.11";
  };
}
