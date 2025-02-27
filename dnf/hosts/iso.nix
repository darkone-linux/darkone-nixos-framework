{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    ./../modules/nix
  ];
  nixpkgs.hostPlatform = "x86_64-linux";
  darkone.host.minimal.enable = true;
}
