# Darkone Network administrator user profile

{
  pkgs,
  lib,
  config,
  ...
}:
import ./admin.nix { inherit pkgs lib config; }
