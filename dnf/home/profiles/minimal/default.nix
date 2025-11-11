# The minimal configuration for all home manager profiles.

{ osConfig, ... }:
{
  imports = [ ./zsh.nix ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Gnome params if graphic env
  darkone.home.gnome.enable = osConfig.darkone.graphic.gnome.enable;
}
