# Specific home manager settings for user guest-teen id:9001 (guest-teen@darkone.yt)

{ pkgs, ... }:
{
  home.username = "guest-teen"; # DO NOT TOUCH!
  home.stateVersion = "25.11"; # DO NOT TOUCH!

  # Write here a specific configuration for current user
  home.packages = with pkgs; [ ];
}
