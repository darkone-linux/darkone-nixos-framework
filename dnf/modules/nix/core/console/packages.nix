# Some useful packages:
#
# * **Base**: vim, less, zip, unzip
# * **Additional**: findutils, fzf, git, htop, neofetch, ranger, tree, wget...

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
    darkone.console.packages.enable = lib.mkEnableOption "Useful base packages";
    darkone.console.packages.enableAdditional = lib.mkEnableOption "Useful additional packages";
  };

  config.environment = lib.mkIf cfg.enable {
    systemPackages =
      with pkgs;
      [
        vim
        less
        unzip
        zip
      ]
      ++ (
        if cfg.enableAdditional then
          [
            findutils # locate
            fzf
            git
            htop
            neofetch
            ranger
            tree
            wget
          ]
        else
          [ ]
      );
    variables.EDITOR = "vim";
  };
}
