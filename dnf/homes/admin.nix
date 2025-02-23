# Non-nix admin user profile

{
  pkgs,
  lib,
  config,
  ...
}:
{
  extraGroups = [
    "networkmanager"
    "wheel"
    "corectrl"
  ];
}
// import ./advanced.nix { inherit pkgs lib config; }
