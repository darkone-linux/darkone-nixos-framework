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

      # VBoxClient drag'n'drop speaks XDnD: in a Wayland session it exits 1 on
      # startup and systemd restarts it every 2s forever (hundreds of failures
      # per hour in the journal). nixpkgs gates `--seamless` on X11 but forgot
      # `--draganddrop`; apply the same condition until it does.
      (lib.mkIf (cfg.enableVirtualbox && config.virtualisation.virtualbox.guest.dragAndDrop) {
        systemd.user.services.virtualboxClientDragAndDrop.unitConfig.ConditionEnvironment =
          "XDG_SESSION_TYPE=x11";
      })

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
