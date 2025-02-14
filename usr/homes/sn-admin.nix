# SN specific user

{
  pkgs,
  lib,
  config,
  login,
  ...
}:
let
  isSnPc = builtins.match "^pc.*" config.networking.hostName != null;
in
{
  initialPassword = "sn2025";
  home = lib.mkIf isSnPc (lib.mkForce "/mnt/home/${login}");
}
// import ./../../lib/homes/admin.nix { inherit pkgs lib config; }
