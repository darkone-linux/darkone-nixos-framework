# Shared directories management service.
#
# :::caution[Auto-activation]
# This service is automatically enabled by services that use NFS or shared media storage.
# :::

{ config, lib, ... }:
let
  inherit (lib)
    hasPrefix
    head
    last
    mapAttrs
    mapAttrsToList
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optional
    types
    ;
  cfg = config.darkone.system.srv-dirs;

  # Directory option -> [ parent option, default sub-directory ].
  layout = {
    nfs = [
      "root"
      "nfs"
    ];
    homes = [
      "nfs"
      "homes"
    ];
    common = [
      "nfs"
      "common"
    ];
    stkTracks = [
      "nfs"
      "stk-tracks"
    ];
    medias = [
      "root"
      "medias"
    ];
    music = [
      "medias"
      "music"
    ];
    videos = [
      "medias"
      "videos"
    ];
    incoming = [
      "medias"
      "incoming"
    ];
    incomingMusic = [
      "incoming"
      "music"
    ];
    incomingVideos = [
      "incoming"
      "videos"
    ];
  };
in
{
  options = {
    darkone.system.srv-dirs.enable = mkOption {
      type = types.bool;
      default = cfg.enableNfs || cfg.enableMedias || cfg.enableStk;
      description = "Enable srv dirs, create the root dir (default /srv)";
    };
    darkone.system.srv-dirs.enableNfs = mkEnableOption "Enable nfs service paths (nfs/common, nfs/homes)";
    darkone.system.srv-dirs.enableMedias = mkEnableOption "Enable media services paths (medias/[videos|music|incomming/...])";
    darkone.system.srv-dirs.enableStk = mkEnableOption "Enable SuperTuxKart tracks share path (nfs/stk-tracks)";

    darkone.system.srv-dirs.root = mkOption {
      type = types.str;
      default = "/srv";
      description = "Root dir for persistant data (/srv)";
    };
    darkone.system.srv-dirs.nfs = mkOption {
      type = types.str;
      description = "NFS root directory (/srv/nfs)";
    };
    darkone.system.srv-dirs.homes = mkOption {
      type = types.str;
      description = "Directory for shared homes (/srv/nfs/homes)";
    };
    darkone.system.srv-dirs.common = mkOption {
      type = types.str;
      description = "Shared common directory (/srv/nfs/common linked to ~/Public)";
    };
    darkone.system.srv-dirs.stkTracks = mkOption {
      type = types.str;
      description = "SuperTuxKart shared tracks directory (/srv/nfs/stk-tracks)";
    };
    darkone.system.srv-dirs.medias = mkOption {
      type = types.str;
      description = "Medias root dir (/srv/medias)";
    };
    darkone.system.srv-dirs.music = mkOption {
      type = types.str;
      description = "Shared music files directory (/srv/medias/music)";
    };
    darkone.system.srv-dirs.videos = mkOption {
      type = types.str;
      description = "Shared video files directory (/srv/medias/videos)";
    };
    darkone.system.srv-dirs.incoming = mkOption {
      type = types.str;
      description = "Shared incoming directory (/srv/medias/incoming write access)";
    };
    darkone.system.srv-dirs.incomingMusic = mkOption {
      type = types.str;
      description = "Shared incoming directory (/srv/medias/incoming/music write access)";
    };
    darkone.system.srv-dirs.incomingVideos = mkOption {
      type = types.str;
      description = "Shared incoming directory (/srv/medias/incoming/videos write access)";
    };
  };

  config = mkMerge [
    {

      # Defaults set here, not in the options: they read one another.
      darkone.system.srv-dirs = mapAttrs (_: l: mkDefault "${cfg.${head l}}/${last l}") layout;

      assertions =
        map
          (opt: {
            assertion = cfg.enable || !cfg.${opt};
            message = "darkone.system.srv-dirs: `${opt}` requires `enable`";
          })
          [
            "enableNfs"
            "enableMedias"
            "enableStk"
          ]
        ++ mapAttrsToList (dir: l: {
          assertion = hasPrefix cfg.${head l} cfg.${dir};
          message = "darkone.system.srv-dirs: `${dir}` must live under `${head l}`";
        }) layout;
    }

    # Configuration when any path is enabled
    (mkIf cfg.enable {

      # Some paths need common-files user / group
      darkone.system.core.enableCommonFilesUser = cfg.enableNfs || cfg.enableMedias;

      # `common-files`: user of the owner and its daemons, group of the
      # services sharing the same files.
      systemd.tmpfiles.rules = [
        "d ${cfg.root} 0755 root root -"
      ]
      ++ optional (cfg.enableNfs || cfg.enableStk) "d ${cfg.nfs} 0755 root root -"
      ++ optional cfg.enableNfs "d ${cfg.homes} 0755 root root -"
      ++ optional cfg.enableNfs "d ${cfg.common} 0770 common-files users -"
      ++ optional cfg.enableStk "d ${cfg.stkTracks} 0775 nobody users -"
      ++ optional cfg.enableMedias "d ${cfg.music} 0770 common-files common-files -"
      ++ optional cfg.enableMedias "d ${cfg.videos} 0770 common-files common-files -"
      ++ optional cfg.enableMedias "d ${cfg.incoming} 0770 common-files common-files -"
      ++ optional cfg.enableMedias "d ${cfg.incomingMusic} 0770 common-files users -"
      ++ optional cfg.enableMedias "d ${cfg.incomingVideos} 0770 common-files users -";
    })
  ];
}
