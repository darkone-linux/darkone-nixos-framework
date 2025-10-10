# Host specific configuration (writable)

{ modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./hardware-configuration.nix
  ];
  system.stateVersion = "25.05";
}
