# Several packages to create music.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.music;
  all-users = builtins.attrNames config.users.users;
  normal-users = builtins.filter (user: config.users.users.${user}.isNormalUser) all-users;
in
{
  options = {
    darkone.graphic.music.enable = lib.mkEnableOption "Music creation module";

    # To update
    # https://amadeuspaulussen.com/blog/2022/favorite-music-production-software-on-linux
    darkone.graphic.music.enablePro = lib.mkEnableOption "Music creation softwares for pros (wip)";
  };

  config = lib.mkIf cfg.enable {

    # Packages
    environment.systemPackages =
      with pkgs;
      [
        audacity
        hydrogen
        lame
        lmms
        mixxx
        mpg123
        mpv
        muse-sounds-manager
        musescore
        ncmpcpp
        soundfont-fluid
        timidity
        vlc
      ]
      ++ (
        if cfg.enablePro then
          [
            ardour
            reaper
            renoise
            rosegarden
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
