# DNF ISO image for fast workstation installs.
#
# -> Build the image:
# nix build .#nixosConfigurations.iso-x86_64-linux.config.system.build.isoImage
#
# -> Install with the image:
# ping dnf-install # locate the IP address
# just full-install my-host nixos 10.1.3.211 # Install "my-host"

{
  modulesPath,
  stdenv,
  lib,
  pkgs,
  ...
}:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  config = {
    nixpkgs.hostPlatform = stdenv.hostPlatform.system;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.systemd-boot.editor = false;
    hardware.enableAllFirmware = true;

    # This sends the key to /etc/ssh/authorized_keys.d/nixos, but with nixos-anywhere
    # it is problematic because nixos-anywhere checks for a key in /home/nixos/.ssh/authorized_keys.
    users.users.nixos.openssh.authorizedKeys.keyFiles = lib.mkForce [ ./../../usr/secrets/nix.pub ];

    # So we trick it with this script that copies the key to /home/nixos/.ssh/authorized_keys.
    # The "chown" does not work — .ssh and its contents stay root:root — but it works with nixos-anywhere.
    system.activationScripts.nixosAuthorizedKeys = ''
      mkdir -p /home/nixos/.ssh
      cp /etc/ssh/authorized_keys.d/nixos /home/nixos/.ssh/authorized_keys
      chown -R nixos:nixos /home/nixos/.ssh
      chmod 700 /home/nixos/.ssh
      chmod 600 /home/nixos/.ssh/authorized_keys
    '';
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
    system.stateVersion = "26.05";
  };
}
