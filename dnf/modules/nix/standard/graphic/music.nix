# Music creation packages and modules.

# TODO: home-manager module
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

    # TODO: To update
    # https://amadeuspaulussen.com/blog/2022/favorite-music-production-software-on-linux
    darkone.graphic.music.enablePro = lib.mkEnableOption "Hard tools for professionals (rose, ardour...)";
    darkone.graphic.music.enableFun = lib.mkEnableOption "Fun audio tools (mixxx...)";
    darkone.graphic.music.enableCli = lib.mkEnableOption "Command line audio tools (mpd, ncmpcpp...)";
    darkone.graphic.music.enableDev = lib.mkEnableOption "Audio software for developers (lilypond...)";
    darkone.graphic.music.enableScore = lib.mkEnableOption "Score softwares (musescore...)";
    darkone.graphic.music.enableBeginner = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Creation tools for beginners (lmms, hydrogen...)";
    };
  };

  config = lib.mkIf cfg.enable {

    # Packages
    environment.systemPackages = with pkgs; [
      (lib.mkIf cfg.enableBeginner hydrogen)
      (lib.mkIf cfg.enableCli mpg123)
      (lib.mkIf cfg.enableCli ncmpcpp)
      (lib.mkIf cfg.enableDev lilypond-with-fonts)
      (lib.mkIf cfg.enableFun mixxx)
      (lib.mkIf cfg.enablePro ardour)
      (lib.mkIf cfg.enablePro reaper)
      (lib.mkIf cfg.enablePro renoise)
      (lib.mkIf cfg.enablePro rosegarden)
      (lib.mkIf cfg.enableScore muse-sounds-manager)
      (lib.mkIf cfg.enableScore musescore)
      audacity
      lame
      mpv
      soundfont-fluid
      timidity
      vlc
    ];

    darkone.system.flatpak.packages = [
      (lib.mkIf cfg.enableDev "org.frescobaldi.Frescobaldi")
      (lib.mkIf cfg.enableBeginner "io.lmms.LMMS")
    ];

    # Users in audio group
    users.groups.audio.members = lib.mkIf cfg.enablePro normal-users;
  };
}
