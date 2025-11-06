{ osConfig, ... }:
{
  imports = [ ./zsh.nix ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Gnome params if graphic env
  darkone.home.gnome.enable = osConfig.darkone.graphic.gnome.enable;

  # Default stateVersion for new homes, TODO: auto
  home.stateVersion = "25.05";
}
