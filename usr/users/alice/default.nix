# Specific home manager settings for user alice id:1001 ()

{ pkgs, ... }:
{
  home.username = "alice"; # DO NOT TOUCH!
  home.stateVersion = "25.11"; # DO NOT TOUCH!

  # Write here a specific configuration for current user
  home.packages = with pkgs; [ ];
}
