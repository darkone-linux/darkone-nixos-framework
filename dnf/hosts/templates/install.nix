# Standalone machine used to install a new host

# TODO: Instable avec impermanence, transfert infra.key impossible, génération des pwd utilisateurs aléatoire...

{
  pkgs,
  lib,
  config,
  ...
}:
let
  hasImpermanence = builtins.hasAttr "persist" config.disko.devices.disk.main.content.partitions;
in
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.editor = false;
  hardware.enableAllFirmware = true;
  nixpkgs.config.allowUnfree = true;
  users.users.nix = {
    uid = 65000;
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keyFiles = [ ./../../../usr/secrets/nix.pub ];
  };
  security.sudo.wheelNeedsPassword = false;
  environment.systemPackages = with pkgs; [ vim ];
  nix.settings = {
    substituters = [ "http://{{gateway}}:8501" ];
  };
  services.openssh.enable = true;
  system.stateVersion = "{{currentStateVersion}}";

  # Minimal impermanence configuration
  # (refined with the real configuration)
  environment.persistence."/persist/system" = lib.mkIf hasImpermanence {
    enable = true;
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/var/lib/lastlog"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
      "/etc/sops/age/infra.key"
    ];
  };
  environment.persistence."/persist" = lib.mkIf hasImpermanence {
    enable = true;
    hideMounts = true;
    users.nix = {
      directories = [
        ".ssh"
        ".gnupg"
        {
          directory = ".local/share";
          mode = "0700";
        }
      ];
    };
  };
  fileSystems = lib.mkIf hasImpermanence {
    "/nix".neededForBoot = true;
    "/boot".neededForBoot = true;
    "/persist/home".neededForBoot = true;
    "/persist/system".neededForBoot = true;
  };
}
