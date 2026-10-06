# Advanced user profile (computer scientists, developers, admins)

{
  pkgs,
  lib,
  config,
  ...
}@args:
lib.mkMerge [
  (import ./normal.nix args)
  { shell = lib.mkIf config.programs.zsh.enable pkgs.zsh; }
]
