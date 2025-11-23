# Specific home manager settings for user guest-student id:9004 (guest-student@darkone.yt)

{ pkgs, ... }:
{
  home.username = "guest-student"; # DO NOT TOUCH!
  home.stateVersion = "25.11"; # DO NOT TOUCH!

  # Write here a specific configuration for current user
  home.packages = with pkgs; [ ];
}
