# Host specific configuration (writable)

{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./hardware-configuration.nix
    ./disko.nix
  ];
  system.stateVersion = "25.11";
}
