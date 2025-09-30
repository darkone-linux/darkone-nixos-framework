# Virt manager + viewer with spice, win-virtio and ovmf.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.virt-manager;
  all-users = builtins.attrNames config.users.users;
  normal-users = builtins.filter (user: config.users.users.${user}.isNormalUser) all-users;
in
{
  options = {
    darkone.graphic.virt-manager.enable = lib.mkEnableOption "Virt manager with dependencies";
  };

  config = lib.mkIf cfg.enable {

    # Dependencies
    environment.systemPackages = with pkgs; [
      virt-viewer
      spice
      spice-gtk
      spice-protocol
      win-virtio
      win-spice
    ];

    # Virt Manager module
    programs.virt-manager.enable = true;
    users.groups.libvirtd.members = normal-users;
    virtualisation = {
      libvirtd = {
        enable = true;
        qemu = {
          ovmf = {
            enable = true;
            packages = [ pkgs.OVMFFull.fd ];
          };
        };
      };
      spiceUSBRedirection.enable = true;
    };
    services.spice-vdagentd.enable = true;
  };
}
