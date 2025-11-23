# Specific home manager settings for user guest-baby id:9003 (guest-baby@darkone.yt)

{ pkgs, ... }:
{
  home.username = "guest-baby"; # DO NOT TOUCH!
  home.stateVersion = "25.11"; # DO NOT TOUCH!

  # Write here a specific configuration for current user
  home.packages = with pkgs; [ ];
}
