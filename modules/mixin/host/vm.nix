# Virtual machines guest tools.

{
  lib,
  config,
  dnfConfig,
  dnfLib,
  host,
  ...
}:
let
  cfg = config.darkone.host.vm;
  profileServicesArgs = {
    profileName = "vm";
    inherit host;
    inherit (dnfConfig) modules;
  };
in
{
  options = {
    darkone.host.vm.enableVirtualbox = lib.mkEnableOption "Virtualbox client";
    darkone.host.vm.enableQemu = lib.mkEnableOption "Qemu/KVM client";
    darkone.host.vm.enableXen = lib.mkEnableOption "Xen client";
  };

  config = lib.mkIf (cfg.enableVirtualbox || cfg.enableXen || cfg.enableQemu) (
    lib.mkMerge [
      {
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
      }

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
