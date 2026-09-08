# Video tools and applications.
#
# Always installs the default player (`celluloid`, GTK4/libadwaita front-end
# over mpv) and gates the rest by audience: `enableTools` (ffmpeg, mlt, vlc,
# video-trimmer, parabolic), `enableEditing` (kdenlive + shotcut from stable
# nixpkgs), `enableCreator` (OBS Studio with `obs-backgroundremoval`,
# `obs-vkcapture`, etc.), `enableUnfree` (davinci-resolve from stable),
# and `enableAlternative` (mpv).
#
# :::caution[Not GNOME Showtime]
# Showtime 50 deadlocks on some files — `get_state(CLOCK_TIME_NONE)` on the
# main thread, [GNOME/showtime#299](https://gitlab.gnome.org/GNOME/showtime/-/work_items/299).
# The stuck process keeps the `org.gnome.Showtime` D-Bus name, so every later
# launch is activated onto it and silently does nothing: no window, no log.
# Unfixed upstream as of 50.0.
# :::

{
  pkgs,
  pkgs-stable,
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
      celluloid
      (lib.mkIf cfg.enableAlternative mpv)
      (lib.mkIf cfg.enableEditing pkgs-stable.kdePackages.kdenlive)
      (lib.mkIf cfg.enableEditing pkgs-stable.shotcut)
      (lib.mkIf cfg.enableTools ffmpeg)
      (lib.mkIf cfg.enableTools mlt)
      (lib.mkIf cfg.enableTools video-trimmer)
      (lib.mkIf cfg.enableTools vlc)
      (lib.mkIf cfg.enableTools parabolic) # yt-dlp frontend
      (lib.mkIf cfg.enableUnfree pkgs-stable.davinci-resolve)
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
