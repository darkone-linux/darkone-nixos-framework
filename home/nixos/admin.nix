# Non-nix admin user profile

{ lib, ... }@args:
lib.mkMerge [
  (import ./advanced.nix args)
  {
    extraGroups = [
      "networkmanager"
      "wheel"
      "corectrl"
    ];
  }
]
