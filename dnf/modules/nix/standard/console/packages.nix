# Some useful console only softwares.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.console.packages;
in
{
  options = {
    darkone.console.packages.enable = lib.mkEnableOption "Vim, less, zip, unzip, tree, wget...";
    darkone.console.packages.enableAdditional = lib.mkEnableOption "Findutils, fzf, git, htop, neofetch, ranger...";
  };

  config.environment = lib.mkIf cfg.enable {
    systemPackages =
      with pkgs;
      [
        git
        less
        tree
        unzip
        vim
        wget
        zip
      ]
      ++ (
        if cfg.enableAdditional then
          [
            findutils # locate
            fzf
            htop
            neofetch
            ranger
          ]
        else
          [ ]
      );
    variables.EDITOR = "vim";
  };
}
