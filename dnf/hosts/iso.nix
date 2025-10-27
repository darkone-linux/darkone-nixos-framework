{ modulesPath, pkgs, lib, ... }:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  config = {
    nixpkgs.hostPlatform = "x86_64-linux";
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.systemd-boot.editor = false;
    hardware.enableAllFirmware = true;
    users.users.nix = {
      uid = 65000;
      password = "p";
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keyFiles = [ ./../../usr/secrets/nix.pub ];
    };
    security.sudo.wheelNeedsPassword = false;
    environment.systemPackages = with pkgs; [ vim ];
    nix.settings = {
      substituters = [
        "http://gateway:8501"
        "https://cache.nixos.org"
      ];
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
    networking.useDHCP = lib.mkDefault true;
    services.openssh.enable = true;
    system.stateVersion = "25.11";
  };
}
