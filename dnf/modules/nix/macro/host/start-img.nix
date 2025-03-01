# Start image for new hosts (used for iso generation).

{
  lib,
  config,
  imgFormat,
  ...
}:
let
  cfg = config.darkone.host.start-img;
in
{
  options = {
    darkone.host.start-img.enable = lib.mkEnableOption "Start minimal iso image";
  };

  config = lib.mkIf cfg.enable {

    # Enable an image depending on requested format
    darkone.host =
      if imgFormat == "vbox" then
        { vm.enableVirtualbox = true; }
      else if imgFormat == "xen" then
        { vm.enableXen = true; }
      else
        {
          # Based on minimal configuration by default
          minimal.enable = lib.mkDefault true;
        };

    users.users.root.initialPassword = "ToChange";

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

    networking.useDHCP = lib.mkDefault true;
    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    # Avoid the stateVersion warning.
    # State based on the system nixos release.
    system.stateVersion = config.system.nixos.release;

  };
}
