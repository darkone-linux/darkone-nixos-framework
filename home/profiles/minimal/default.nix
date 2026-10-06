# The minimal configuration for all home manager profiles.

{
  lib,
  osConfig,
  zone,
  ...
}:
{
  imports = [
    ./features.nix
    ./nfs.nix
  ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Environment
  home.language.base = lib.mkDefault zone.locale;

  # Gnome params if graphic env
  darkone.home.gnome.enable = lib.mkDefault osConfig.darkone.graphic.gnome.enable;

  # Mime types improvements for DNF
  darkone.home.mime.enable = lib.mkDefault true;

  # Local binaries access
  home.sessionPath = [ "$HOME/.local/bin" ];
}
