{ modulesPath, pkgs, ... }:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  config = {
    nixpkgs.hostPlatform = stdenv.hostPlatform.system;
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = false;
    boot.loader.systemd-boot.editor = false;
    hardware.enableAllFirmware = true;
    users.users.nix = {
      uid = 65000;
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keyFiles = [ ./../../usr/secrets/nix.pub ];
    };
    security.sudo.wheelNeedsPassword = false;
    environment.systemPackages = with pkgs; [ vim ];
    nix.settings = {
      # substituters = [
      #   #"http://gateway.arthur.lan:8501" # TODO
      #   "https://cache.nixos.org"
      # ];
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
    networking.useDHCP = true;
    networking.hostName = "dnf-install";
    services.openssh.enable = true;
    system.stateVersion = "26.05";
  };
}
