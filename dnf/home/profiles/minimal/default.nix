# The minimal configuration for all home manager profiles.

{ osConfig, zone, ... }:
{
  imports = [
    ./zsh.nix
    ./nfs.nix
  ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Environment
  home.language.base = zone.locale;

  # Gnome params if graphic env
  darkone.home.gnome.enable = osConfig.darkone.graphic.gnome.enable;

  # Mime types improvements for DNF
  darkone.home.mime.enable = true;
}
