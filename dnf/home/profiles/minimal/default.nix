# The minimal configuration for all home manager profiles.

{ osConfig, network, ... }:
{
  imports = [
    ./zsh.nix
    ./nfs.nix
  ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Environment
  home.language.base = network.locale;

  # Gnome params if graphic env
  darkone.home.gnome.enable = osConfig.darkone.graphic.gnome.enable;
}
