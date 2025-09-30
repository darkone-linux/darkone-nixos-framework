# Preconfigured obsidian installation.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.obsidian;
in
{
  options = {
    darkone.graphic.obsidian.enable = lib.mkEnableOption "Default useful packages";
  };

  config = lib.mkIf cfg.enable {

    # Unfree exception for obsidian
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "obsidian" ];

    # Packages
    environment.systemPackages = with pkgs; [ obsidian ];
  };
}
