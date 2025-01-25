# MAO

{
  lib,
  config,
  pkgs,
  pkgs-stable,
  ...
}:
let
  cfg = config.darkone.graphic.music;
  all-users = builtins.attrNames config.users.users;
  normal-users = builtins.filter (user: config.users.users.${user}.isNormalUser) all-users;
in
{
  options = {
    darkone.graphic.music = {
      enable = lib.mkEnableOption "Music creation module";

      # To update
      # https://amadeuspaulussen.com/blog/2022/favorite-music-production-software-on-linux
      enablePro = lib.mkEnableOption "Music creation softwares for pros (wip)";
    };
  };

  config = lib.mkIf cfg.enable {

    # Packages
    environment.systemPackages =
      [
        pkgs.audacity
        pkgs.hydrogen
        pkgs.lame
        pkgs-stable.lmms
        pkgs.mixxx
        pkgs.mpg123
        pkgs.mpv
        pkgs.muse-sounds-manager
        pkgs.musescore
        pkgs.ncmpcpp
        pkgs.soundfont-fluid
        pkgs.timidity
        pkgs.vlc
      ]
      ++ (
        if cfg.enablePro then
          [
            pkgs.ardour
            pkgs.reaper
            pkgs.renoise
            pkgs.rosegarden
          ]
        else
          [ ]
      );

    # Users in audio group
    users.groups.audio.members = lib.mkIf cfg.enablePro normal-users;

    # Enable musnix real-time audio configuration for NixOS
    #musnix.enable = lib.mkIf cfg.enablePro true;
  };
}
