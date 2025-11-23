# Specific home manager settings for user guest id:9000 (guest@darkone.yt)

{ pkgs, ... }:
{
  home.username = "guest"; # DO NOT TOUCH!
  home.stateVersion = "25.11"; # DO NOT TOUCH!

  # Write here a specific configuration for current user
  home.packages = with pkgs; [ ];
}
