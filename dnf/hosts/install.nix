# Standalone machine used to install a new host

{ pkgs, ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.editor = false;
  hardware.enableAllFirmware = true;
  nixpkgs.config.allowUnfree = true;
  users.users.nix = {
    uid = 65000;
    initialPassword = "nixos";
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;
  environment.systemPackages = with pkgs; [ vim ];
  nix.settings = {
    substituters = [ "http://gateway:8501" ];
  };
  services.openssh.enable = true;
  system.stateVersion = "25.05";
}
