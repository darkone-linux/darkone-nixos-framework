# Video tools and apps.

{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.darkone.home.video;
in
{
  options = {
    darkone.home.video.enable = lib.mkEnableOption "Video creation and tools home module";
    darkone.home.video.enableTools = lib.mkEnableOption "Video tools for professionals";
    darkone.home.video.enableCreation = lib.mkEnableOption "Video creation tools (kdenlive...)";
  };

  config = lib.mkIf cfg.enable {

    # Nix packages TODO: more apps
    home.packages = with pkgs; [
      (lib.mkIf cfg.enableTools totem)
      (lib.mkIf cfg.enableTools vlc)
      (lib.mkIf cfg.enableTools mpv)
      (lib.mkIf cfg.enableCreation kdePackages.kdenlive)
    ];
  };
}
