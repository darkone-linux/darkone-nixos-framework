# Image iso DNF pour installations rapides de postes.
#
# -> Pour générer l'image :
# nix build .#nixosConfigurations.iso-x86_64-linux.config.system.build.isoImage
#
# -> Pour installer avec l'image :
# ping dnf-install # pour repérer l'adresse ip
# just full-install mon-poste nixos 10.1.3.211 # Installation de "mon-poste"

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

    # Ceci va envoyer la clé dans /etc/ssh/authorized_keys.d/nixos, mais avec nixos-anywhere c'est
    # problématique car ce dernier vérifie s'il y a une clé dans /home/nixos/.ssh/authorized_keys
    users.users.nixos.openssh.authorizedKeys.keyFiles = lib.mkForce [ ./../../usr/secrets/nix.pub ];

    # Alors on le trompe avec ce script qui copie la clé dans /home/nixos/.ssh/authorized_keys
    # Le "chown" ne fonctionne pas, .ssh et son contenu sont root:root, mais avec nixos-anywhere ça marche
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
