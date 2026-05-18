# Computer science student profile

{
  pkgs,
  lib,
  config,
  ...
}:
import ./advanced.nix { inherit pkgs lib config; }
