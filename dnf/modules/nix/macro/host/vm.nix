{ lib, config, ... }:
let
  cfg = config.darkone.host.vm;
in
{
  imports = [ ./minimal.nix ];

  options = {
    darkone.host.vm = {
      enableVirtualbox = lib.mkEnableOption "Virtualbox client";
      enableXen = lib.mkEnableOption "Xen client";
    };
  };

  config = lib.mkIf (cfg.enableVirtualbox || cfg.enableXen) {

    # Based on server configuration
    darkone.host.server.enable = lib.mkDefault true;

    virtualisation.virtualbox = lib.mkIf cfg.enableVirtualbox { guest.enable = true; };

    services.xe-guest-utilities = lib.mkIf cfg.enableXen { enable = true; };

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
