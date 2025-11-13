# Graphical music and sound creation apps.

{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.darkone.home.music;
in
{
  options = {
    darkone.home.music.enable = lib.mkEnableOption "Music creation home module";

    # TODO: WIP
    # https://amadeuspaulussen.com/blog/2022/favorite-music-production-software-on-linux
    darkone.home.music.enablePro = lib.mkEnableOption "Hard tools for professionals (rose, ardour...)";
    darkone.home.music.enableFun = lib.mkEnableOption "Fun audio tools (mixxx...)";
    darkone.home.music.enableCli = lib.mkEnableOption "Command line audio tools (mpd, ncmpcpp...)";
    darkone.home.music.enableDev = lib.mkEnableOption "Audio software for developers (lilypond...)";
    darkone.home.music.enableScore = lib.mkEnableOption "Score softwares (musescore...)";
    darkone.home.music.enableBeginner = lib.mkEnableOption "Creation tools for beginners (lmms, hydrogen...)";
  };

  config = lib.mkIf cfg.enable {

    # Nix packages
    home.packages = with pkgs; [
      #(lib.mkIf cfg.enableBeginner lmms) # Compilation failed
      (lib.mkIf (cfg.enableDev || cfg.enableCli) lilypond-with-fonts)
      (lib.mkIf cfg.enableBeginner decibels)
      (lib.mkIf cfg.enableBeginner hydrogen)
      (lib.mkIf cfg.enableCli mpg123)
      (lib.mkIf cfg.enableCli ncmpcpp)
      (lib.mkIf cfg.enableFun mixxx)
      (lib.mkIf cfg.enableFun mousai) # Identify any songs in seconds
      (lib.mkIf cfg.enablePro ardour)
      (lib.mkIf cfg.enablePro reaper)
      (lib.mkIf cfg.enablePro renoise)
      (lib.mkIf cfg.enablePro rosegarden)
      (lib.mkIf cfg.enableScore muse-sounds-manager)
      (lib.mkIf cfg.enableScore musescore)
      audacity
      gnome-music
      lame
      soundfont-fluid
      timidity
    ];

    # https://github.com/wwmm/easyeffects
    services.easyeffects = {
      enable = true;
      preset = "easyeffects-fw16";
    };

    # Flatpak packages
    services.flatpak.packages = [
      (lib.mkIf cfg.enableDev "org.frescobaldi.Frescobaldi")
      (lib.mkIf cfg.enableBeginner "io.lmms.LMMS")
    ];

    # TODO: Users in audio group (cannot do than in homemanager?)
    # LETIN: all-users = builtins.attrNames config.users.users;
    # LETIN: normal-users = builtins.filter (user: config.users.users.${user}.isNormalUser) all-users;
    #users.groups.audio.members = lib.mkIf cfg.enablePro normal-users;
  };
}
