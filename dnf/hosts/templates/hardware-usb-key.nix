# Specific hardware configuration for usb keys

{ lib, ... }:
{
  boot = {
    initrd.availableKernelModules = [
      "ahci"
      "xhci_pci"
      "ehci_pci"
      "usb_storage"
      "sd_mod"
      "sdhci_pci"
      "nvme"
      "uas"
      "usbhid"
      "sr_mod"
    ];
    initrd.kernelModules = [ ];
    kernelModules = [
      "kvm-intel"
      "kvm-amd"
    ];
    extraModulePackages = [ ];
    loader.efi.canTouchEfiVariables = lib.mkForce false;
  };

  hardware = {
    enableRedistributableFirmware = lib.mkForce true;
    graphics = {
      enable = true;
      enable32Bit = true;
    };
    bluetooth.enable = true;
  };

  nixpkgs = {
    hostPlatform = lib.mkDefault "x86_64-linux";
    config.allowUnfree = lib.mkForce true;
  };
}
