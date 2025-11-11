# Specific home manager settings for user nix id:65000 ()

{ pkgs, ... }:
{
  home.username = "nix"; # DO NOT TOUCH!
  home.stateVersion = "25.11"; # DO NOT TOUCH!

  # Write here a specific configuration for current user
  home.packages = with pkgs; [ ];
}
