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
    darkone.home.video.enableEditing = lib.mkEnableOption "Video editing tools (kdenlive...)";
    darkone.home.video.enableCreator = lib.mkEnableOption "Video creator tools (obs...)";
    darkone.home.video.enableUnfree = lib.mkEnableOption "Unfree video apps (davinci...)";
    darkone.home.video.enableAlternative = lib.mkEnableOption "Alternative video apps (mpv...)";
  };

  config = lib.mkIf cfg.enable {

    home.packages = with pkgs; [
      #(lib.mkIf cfg.enableTools handbrake)
      showtime
      (lib.mkIf cfg.enableAlternative mpv)
      (lib.mkIf cfg.enableEditing kdePackages.kdenlive)
      (lib.mkIf cfg.enableEditing shotcut)
      (lib.mkIf cfg.enableTools ffmpeg)
      (lib.mkIf cfg.enableTools mlt)
      (lib.mkIf cfg.enableTools video-trimmer)
      (lib.mkIf cfg.enableTools vlc)
      (lib.mkIf cfg.enableUnfree davinci-resolve)
    ];

    programs.obs-studio = lib.mkIf cfg.enableCreator {
      enable = true;
      plugins = with pkgs.obs-studio-plugins; [
        obs-backgroundremoval
        obs-gstreamer
        obs-transition-table
        obs-vaapi
        obs-vkcapture
      ];
    };
  };
}
