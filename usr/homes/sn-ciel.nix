{
  pkgs,
  lib,
  config,
  ...
}:
{ initialPassword = "sn2025"; } // import ./sn-user.nix { inherit pkgs lib config; }
