# SN specific user

{
  pkgs,
  lib,
  config,
  ...
}:
{ initialPassword = "sn2025"; } // import ./../../lib/homes/admin.nix { inherit pkgs lib config; }
