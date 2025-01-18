# Advanced user profile (computer scientists, developers, admins)

{
  pkgs,
  lib,
  config,
  ...
}:
{
  shell = lib.mkIf config.programs.zsh.enable pkgs.zsh;
}
// builtins.import ./minimal.nix { inherit pkgs; }
