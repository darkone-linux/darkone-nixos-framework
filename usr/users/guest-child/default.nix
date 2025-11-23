# Specific home manager settings for user guest-child id:9002 (guest-child@darkone.yt)

{ pkgs, ... }:
{
  home.username = "guest-child"; # DO NOT TOUCH!
  home.stateVersion = "25.11"; # DO NOT TOUCH!

  # Write here a specific configuration for current user
  home.packages = with pkgs; [ ];
}
