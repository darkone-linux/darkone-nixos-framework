# Graphical music and sound creation apps.
#
# Categorised by audience: `enablePro` (ardour, reaper, renoise,
# rosegarden), `enableCreator` (decibels, hydrogen), `enableScore`
# (musescore, muse-sounds-manager), `enableFun` (mixxx, mousai),
# `enableCli` (mpg123, cmus, lilypond), `enableEasy` (gnome-music vs.
# audacious), `enableMpd` (MPD daemon, ncmpcpp, mpdris2), and
# `enableDev` (lilypond).
#
# :::note[NFS-aware music library]
# When the host is an NFS client and the network exposes an `nfs` service
# in the same zone, MPD reads its music directory from the NFS mount
# (`/mnt/nfs/homes/$USER/Music`). Otherwise it falls back to the local
# `srv-dirs.homes` value, then to `~/Music`.
# :::

{
  pkgs,
  pkgs-stable,
  lib,
  host,
  hosts,
  zone,
  network,
  config,
  osConfig,
  dnfLib,
  ...
}:

let
  cfg = config.darkone.home.music;
  #graphic = osConfig.darkone.graphic.gnome.enable;
  hasNfsServer = osConfig.darkone.service.nfs.enable;
  nfsServer = (dnfLib.findService "nfs" zone.name network.services).host;
  isNfsClient =
    host.hostname != nfsServer
    && lib.hasAttr "nfs-client" host.features
    && host.features.nfs-client == (lib.findFirst (h: h.hostname == nfsServer) null hosts).zone;
  mpdMusicDir =
    if isNfsClient then
      "/mnt/nfs/homes/${config.home.username}/Music"
    else
      "${osConfig.darkone.system.srv-dirs.homes}/${config.home.username}/Music";
  mpdAddress = config.services.mpd.network.listenAddress;
in
{
  options = {
    darkone.home.music.enable = lib.mkEnableOption "Music creation home module";

    # TODO: WIP
    # https://amadeuspaulussen.com/blog/2022/favorite-music-production-software-on-linux
    darkone.home.music.enablePro = lib.mkEnableOption "Hard tools for professionals (rose, ardour...)";
    darkone.home.music.enableFun = lib.mkEnableOption "Fun audio tools (mixxx...)";
    darkone.home.music.enableCli = lib.mkEnableOption "Command line audio tools (mpg123, cmus, moc...)";
    darkone.home.music.enableDev = lib.mkEnableOption "Audio software for developers (lilypond...)";
    darkone.home.music.enableMpd = lib.mkEnableOption "MPD daemon and players (mpd, ncmpcpp...)";
    darkone.home.music.enableEasy = lib.mkEnableOption "Easy tools instead of efficient (gnome-music vs audacious...)";
    darkone.home.music.enableScore = lib.mkEnableOption "Score softwares (musescore...)";
    darkone.home.music.enableCreator = lib.mkEnableOption "Creation tools for beginners (lmms, hydrogen...)";
  };

  config = lib.mkIf cfg.enable {

    # TODO audacious: écrire dans .config/audacious/config s'il n'existe pas :
    # [audqt]
    # theme=dark

    # Frescobaldi
    #nixpkgs.config.permittedInsecurePackages = [ "qtwebengine-5.15.19" ];
    #nixpkgs.config.permittedInsecurePackages = lib.optional cfg.enableScore "qtwebengine-5.15.19";

    # Nix packages
    home.packages = with pkgs; [
      #(lib.mkIf cfg.enableCreator lmms) # Compilation fail
      #(lib.mkIf (!cfg.enableEasy) lollypop) # Bof
      (lib.mkIf (cfg.enableDev || cfg.enableCli) lilypond-with-fonts)
      (lib.mkIf cfg.enableCreator decibels)
      (lib.mkIf cfg.enableCreator hydrogen)
      (lib.mkIf cfg.enableCli mpg123)
      (lib.mkIf cfg.enableCli cmus)
      #(lib.mkIf cfg.enableCli moc) # Compilation fail
      #(lib.mkIf cfg.enableMpd cantata) # Do not connect to MPD server
      # (lib.mkIf (cfg.enableMpd && graphic) (
      #   ymuse.overrideAttrs (old: {
      #     postInstall = (old.postInstall or "") + ''
      #       wrapProgram $out/bin/ymuse \
      #         --set GTK_THEME            "Adwaita:dark" \
      #         --set GTK_DARK_THEME       "1" \
      #         --set ADW_DISABLE_PORTAL   "1"
      #     '';
      #   })
      # )) # Not dark without this hack, too long to build...
      #(lib.mkIf cfg.enableMpd sonata) # ymuse alternative (old, not dark)
      #(lib.mkIf cfg.enableMpd ario) # Not free dependency
      (lib.mkIf cfg.enableFun pkgs-stable.mixxx)
      (lib.mkIf cfg.enableFun mousai) # Identify any songs in seconds
      (lib.mkIf cfg.enablePro ardour)
      (lib.mkIf cfg.enablePro reaper)
      (lib.mkIf cfg.enablePro renoise)
      (lib.mkIf cfg.enablePro rosegarden)
      (lib.mkIf cfg.enableScore muse-sounds-manager)
      (lib.mkIf cfg.enableScore musescore)
      #(lib.mkIf cfg.enableScore frescobaldi) # FAIL
      (lib.mkIf cfg.enableEasy gnome-music)
      (lib.mkIf cfg.enableMpd gnomeExtensions.mpris-label)
      (lib.mkIf (!cfg.enableEasy) audacious)
      lame
      soundfont-fluid
      timidity
    ];

    # MPD
    services.mpd = lib.mkIf cfg.enableMpd {
      enable = true;
      enableSessionVariables = true;
      network.listenAddress = "0.0.0.0";
      extraConfig = ''
        audio_output {
          type "pipewire"
          name "PipeWire Sound Server"
        }

        # Or PulseAudio:
        # audio_output {
        #   type "pulse"
        #   name "PulseAudio"
        # }

        max_connections "20"
      '';
      musicDirectory =
        if hasNfsServer then
          mpdMusicDir
        else
          (
            if config.xdg.userDirs.enable then
              config.xdg.userDirs.music
            else
              "${config.home.homeDirectory}/Music"
          );
    };
    services.mpd-mpris.enable = cfg.enableMpd;
    services.mpdris2 = lib.mkIf cfg.enableMpd {
      enable = true;
      mpd.host = mpdAddress;
    };
    programs.ncmpcpp.enable = cfg.enableMpd;
    home.sessionVariables = lib.mkIf cfg.enableMpd {
      MPD_HOST = mpdAddress;
      MPD_PORT = toString config.services.mpd.network.port;
    };

    # TODO: Users in audio group
    # LETIN: all-users = builtins.attrNames config.users.users;
    # LETIN: normal-users = builtins.filter (user: config.users.users.${user}.isNormalUser) all-users;
    #users.groups.audio.members = lib.mkIf cfg.enablePro normal-users;
  };
}
