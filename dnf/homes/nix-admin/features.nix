# Nix admin specific configuration

{ lib, ... }:
{
  darkone.home.advanced.enableNixAdmin = lib.mkDefault true;
}
