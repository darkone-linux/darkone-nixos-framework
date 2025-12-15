{ config, lib, ... }:
with lib;
let
  cfg = config.darkone.system.srv-dirs;
in
{
  options = {
    darkone.system.srv-dirs.enable = mkOption {
      type = types.bool;
      default = cfg.enableNfs || cfg.enableMedias;
      description = "Enable srv dirs, create the root dir (default /srv)";
    };
    darkone.system.srv-dirs.enableNfs = mkEnableOption "Enable nfs service paths (nfs/common, nfs/homes)";
    darkone.system.srv-dirs.enableMedias = mkEnableOption "Enable media services paths (medias/[videos|music|incomming/...])";

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
      # Default values (here to avoid infinite loop)
      darkone.system.srv-dirs.nfs = mkDefault "${cfg.root}/nfs";
      darkone.system.srv-dirs.homes = mkDefault "${cfg.nfs}/homes";
      darkone.system.srv-dirs.common = mkDefault "${cfg.nfs}/common";
      darkone.system.srv-dirs.medias = mkDefault "${cfg.root}/medias";
      darkone.system.srv-dirs.music = mkDefault "${cfg.medias}/music";
      darkone.system.srv-dirs.videos = mkDefault "${cfg.medias}/videos";
      darkone.system.srv-dirs.incoming = mkDefault "${cfg.medias}/incoming";
      darkone.system.srv-dirs.incomingMusic = mkDefault "${cfg.incoming}/music";
      darkone.system.srv-dirs.incomingVideos = mkDefault "${cfg.incoming}/videos";

      # Assertions for path prefixes
      assertions = [
        {
          assertion = cfg.enable || !cfg.enableNfs;
          message = "Missing enable with enableNfs";
        }
        {
          assertion = cfg.enable || !cfg.enableMedias;
          message = "Missing enable with enableMedias";
        }
        {
          assertion = hasPrefix cfg.root cfg.nfs;
          message = "Root dir isn't nfs dir prefix";
        }
        {
          assertion = hasPrefix cfg.nfs cfg.homes;
          message = "Nfs dir isn't homes dir prefix";
        }
        {
          assertion = hasPrefix cfg.nfs cfg.common;
          message = "Nfs dir isn't common dir prefix";
        }
        {
          assertion = hasPrefix cfg.root cfg.medias;
          message = "Root dir isn't medias dir prefix";
        }
        {
          assertion = hasPrefix cfg.medias cfg.music;
          message = "Medias dir isn't music dir prefix";
        }
        {
          assertion = hasPrefix cfg.medias cfg.videos;
          message = "Medias dir isn't videos dir prefix";
        }
        {
          assertion = hasPrefix cfg.medias cfg.incoming;
          message = "Medias dir isn't incoming dir prefix";
        }
        {
          assertion = hasPrefix cfg.incoming cfg.incomingMusic;
          message = "Incoming dir isn't incomingMusic dir prefix";
        }
        {
          assertion = hasPrefix cfg.incoming cfg.incomingVideos;
          message = "Incoming dir isn't incomingVideos dir prefix";
        }
      ];
    }

    # Configuration when any path is enabled
    (mkIf cfg.enable {

      # Some paths need common-files user / group
      darkone.system.core.enableCommonFilesUser = cfg.enableNfs || cfg.enableMedias;

      # Directories creation
      # -> common-files user is used by the user and its deamons
      # -> common-files group is used by several services to access the same files
      systemd.tmpfiles.rules = [
        "d ${cfg.root} 0755 root root -"
      ]
      ++ optional cfg.enableNfs "d ${cfg.homes} 0755 root root -"
      ++ optional cfg.enableNfs "d ${cfg.common} 0770 common-files users -"
      ++ optional cfg.enableMedias "d ${cfg.music} 0770 common-files common-files -"
      ++ optional cfg.enableMedias "d ${cfg.videos} 0770 common-files common-files -"
      ++ optional cfg.enableMedias "d ${cfg.incoming} 0770 common-files common-files -"
      ++ optional cfg.enableMedias "d ${cfg.incomingMusic} 0770 common-files users -"
      ++ optional cfg.enableMedias "d ${cfg.incomingVideos} 0770 common-files users -";
    })
  ];
}
