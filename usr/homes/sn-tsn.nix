{
  pkgs,
  lib,
  config,
  login,
  ...
}:
{
  initialPassword = "sn2025";
}
// import ./sn-user.nix {
  inherit
    pkgs
    lib
    config
    login
    ;
}
