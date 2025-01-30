# VBOX virtual machine profile

{ lib, config, ... }:
let
  cfg = config.darkone.host.vbox;
in
{
  options = {
    darkone.host.vbox.enable = lib.mkEnableOption "A personalized virtualbox config";
  };

  config = lib.mkIf cfg.enable {

    # Darkone modules
    darkone = {

      # Virtualbox VM
      host.vm.enableVirtualbox = true;

      # For advanced users
      theme.advanced.enable = true;
    };

    # Vbox common hardware configuration
    boot.initrd.availableKernelModules = [
      "ata_piix"
      "ohci_pci"
      "ehci_pci"
      "ahci"
      "sd_mod"
      "sr_mod"
    ];
    boot.initrd.kernelModules = [ ];
    boot.kernelModules = [ ];
    boot.extraModulePackages = [ ];
    fileSystems."/" = {
      device = "/dev/disk/by-uuid/9b47d3f9-5cf1-417a-87d9-6e56d37ce27b";
      fsType = "btrfs";
      options = [ "subvol=@" ];
    };
    fileSystems."/home" = {
      device = "/dev/disk/by-uuid/9b47d3f9-5cf1-417a-87d9-6e56d37ce27b";
      fsType = "btrfs";
      options = [ "subvol=@home" ];
    };
    fileSystems."/boot" = {
      device = "/dev/disk/by-uuid/1A9B-7196";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
    swapDevices = [ { device = "/dev/disk/by-uuid/9f3bfa92-03e9-4e05-a013-3893b7b5c9c4"; } ];
    networking.useDHCP = lib.mkDefault true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    virtualisation.virtualbox.guest.enable = true;

    system.stateVersion = "25.05";
  };
}
