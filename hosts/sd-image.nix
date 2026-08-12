# DNF bootable SD image for Raspberry Pi first-install.
#
# Generic, board-agnostic install layer: combined in `mkConfigurations` with a
# `nixos-raspberrypi` board base (`raspberry-pi-5.base`, ...) and the `sd-image`
# module, which together set the platform, vendor kernel/firmware/bootloader and
# the image builder. This file only adds the reachable-on-first-boot bits (SSH +
# admin key + DHCP) so the operator can then deploy the real host via colmena.
#
# -> Build the image:
# nix build .#nixosConfigurations.sd-image-raspberry-pi-5.config.system.build.sdImage
#
# :::note[Boot & platform]
# `nixpkgs.hostPlatform`, the bootloader and the kernel come from the board base
# module — do NOT set them here (it would conflict with nixos-raspberrypi).
# :::

{
  lib,
  pkgs,
  workDir ? null,
  ...
}:
{
  config = {

    # Consumer-provided admin pubkey for the colmena deploy user (`nix`, cf.
    # colmena `targetUser`). The framework standalone image ships no key.
    users.users.nix = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keyFiles = lib.mkIf (workDir != null) [ (workDir + "/usr/secrets/nix.pub") ];
    };

    security.sudo.wheelNeedsPassword = false;
    environment.systemPackages = with pkgs; [ vim ];
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
    networking.useDHCP = lib.mkForce true;
    networking.hostName = "dnf-install";
    services.openssh.enable = true;

    # The board base pulls in ZFS support, and `stateVersion` below predates
    # 26.11, so `forceImportRoot` would fall back to its old `true` default and
    # warn. `false` is both the 26.11 default and the safe value: a forced
    # import bypasses the guard against adopting a pool owned by another host.
    boot.zfs.forceImportRoot = false;

    system.stateVersion = "26.05";
  };
}
