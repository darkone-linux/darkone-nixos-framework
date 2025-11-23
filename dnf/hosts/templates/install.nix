# Standalone machine used to install a new host - DEPRECATED

{ pkgs, ... }:
{
  console.keyMap = "fr"; # TODO: auto
  boot.initrd.systemd.enable = true; # To set the console keyMap before asking luks password
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.editor = false;
  hardware.enableAllFirmware = true;
  nixpkgs.config.allowUnfree = true;
  users.users.nix = {
    uid = 65000;
    isNormalUser = true;
    initialPassword = "NixOS!";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keyFiles = [ ./../../../usr/secrets/nix.pub ];
  };
  security.sudo.wheelNeedsPassword = false;
  environment.systemPackages = with pkgs; [ vim ];
  #nix.settings = {
  #  substituters = [ "http://{{gateway}}:8501" ];
  #};
  services.openssh.enable = true;
  system.stateVersion = "{{currentStateVersion}}";
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };
}
