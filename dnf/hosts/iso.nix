{
  modulesPath,
  pkgs,
  lib,
  config,
  ...
}:
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  config = {
    nixpkgs.hostPlatform = "x86_64-linux";

    # Is a minimal host...
    darkone.host.minimal.enable = true;

    # nixos user with dnf / zsh environment
    programs.zsh.enable = true;
    users.users.nixos = import ./../homes/nix-admin.nix { inherit pkgs lib config; };
  };
}
