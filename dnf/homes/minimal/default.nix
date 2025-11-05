{ ... }:
{
  imports = [ ./zsh.nix ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Default stateVersion for new homes, TODO: auto
  home.stateVersion = "25.05";
}
