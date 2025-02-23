# A unique user profile

{
  pkgs,
  lib,
  config,
  ...
}:
import ./../../dnf/homes/nix-admin.nix { inherit pkgs lib config; }
