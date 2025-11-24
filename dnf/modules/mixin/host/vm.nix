# Virtual machines guest tools.

{ lib, config, ... }:
let
  cfg = config.darkone.host.vm;
in
{
  options = {
    darkone.host.vm = {
      enableVirtualbox = lib.mkEnableOption "Virtualbox client";
      enableQemu = lib.mkEnableOption "Qemu/KVM client";
      enableXen = lib.mkEnableOption "Xen client";
    };
  };

  config = lib.mkIf (cfg.enableVirtualbox || cfg.enableXen || cfg.enableQemu) {

    # Based on server configuration
    darkone.host.server.enable = lib.mkDefault true;

    # VM parameters
    virtualisation.virtualbox.guest.enable = cfg.enableVirtualbox;
    services.qemuGuest.enable = cfg.enableQemu;
    services.xe-guest-utilities.enable = cfg.enableXen;
    boot.initrd.kernelModules = lib.mkIf cfg.enableXen [
      "xen-blkfront"
      "xen-tpmfront"
      "xen-kbdfront"
      "xen-fbfront"
      "xen-netfront"
      "xen-pcifront"
      "xen-scsifront"
    ];
  };
}
