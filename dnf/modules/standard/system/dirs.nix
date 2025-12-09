{ config, lib, ... }:
with lib;
let
  cfg = config.darkone.system.dirs;
in
{
  options = {
    darkone.system.dirs.enableHomes = mkEnableOption "Enable homes path";
    darkone.system.dirs.enableCommon = mkEnableOption "Enable common path";
    darkone.system.dirs.enablePictures = mkEnableOption "Enable pictures path";
    darkone.system.dirs.enableMusic = mkEnableOption "Enable music path";
    darkone.system.dirs.enableVideo = mkEnableOption "Enable video path";
    darkone.system.dirs.enableIncoming = mkEnableOption "Enable incoming path";
    darkone.system.dirs.enableIncomingMusic = mkEnableOption "Enable incoming/music path";

    darkone.system.dirs.root = mkOption {
      type = types.str;
      default = "/export";
      example = "/srv";
      description = "Root dir for NFS shares and persistant data";
    };
    darkone.system.dirs.homes = mkOption {
      type = types.str;
      description = "Root directory for shared homes";
    };
    darkone.system.dirs.common = mkOption {
      type = types.str;
      description = "Shared common directory (~/Public)";
    };
    darkone.system.dirs.pictures = mkOption {
      type = types.str;
      description = "Shared pictures directory (Nextcloud, Immich...)";
    };
    darkone.system.dirs.music = mkOption {
      type = types.str;
      description = "Shared music files directory (Jellyfin, Beets, Navidrome...)";
    };
    darkone.system.dirs.video = mkOption {
      type = types.str;
      description = "Shared video files directory (Jellyfin...)";
    };
    darkone.system.dirs.incoming = mkOption {
      type = types.str;
      description = "Shared incoming directory (write access)";
    };
    darkone.system.dirs.incomingMusic = mkOption {
      type = types.str;
      description = "Shared incoming music directory (Beets source files)";
    };
  };

  config = mkMerge [

    # Default values (here to avoid infinite loop)
    {
      darkone.system.dirs.homes = mkDefault "${cfg.root}/homes";
      darkone.system.dirs.common = mkDefault "${cfg.root}/common";
      darkone.system.dirs.pictures = mkDefault "${cfg.root}/pictures";
      darkone.system.dirs.music = mkDefault "${cfg.root}/music";
      darkone.system.dirs.video = mkDefault "${cfg.root}/video";
      darkone.system.dirs.incoming = mkDefault "${cfg.common}/incoming";
      darkone.system.dirs.incomingMusic = mkDefault "${cfg.incoming}/music";
    }

    # Validation assertions
    (mkIf (cfg.enableIncomingMusic && !cfg.enableIncoming) {
      assertions = [
        {
          assertion = false;
          message = "You must enable incoming with incoming/music";
        }
      ];
    })

    # Configuration when any path is enabled
    (mkIf
      (
        cfg.enableHomes
        || cfg.enableCommon
        || cfg.enablePictures
        || cfg.enableMusic
        || cfg.enableVideo
        || cfg.enableIncoming
        || cfg.enableIncomingMusic
      )
      {
        # Assertions for path prefixes
        assertions = [
          {
            assertion = hasPrefix cfg.root cfg.homes;
            message = "Root dir isn't homes dir prefix";
          }
          {
            assertion = hasPrefix cfg.root cfg.common;
            message = "Root dir isn't common dir prefix";
          }
          {
            assertion = hasPrefix cfg.root cfg.pictures;
            message = "Root dir isn't pictures dir prefix";
          }
          {
            assertion = hasPrefix cfg.root cfg.music;
            message = "Root dir isn't music dir prefix";
          }
          {
            assertion = hasPrefix cfg.root cfg.video;
            message = "Root dir isn't video dir prefix";
          }
          {
            assertion = hasPrefix cfg.root cfg.incoming;
            message = "Root dir isn't incoming dir prefix";
          }
          {
            assertion = hasPrefix cfg.common cfg.incoming;
            message = "Common dir isn't incoming dir prefix";
          }
          {
            assertion = hasPrefix cfg.incoming cfg.incomingMusic;
            message = "Incoming dir isn't incoming music dir prefix";
          }
        ];

        # Some paths need common-files user / group
        darkone.system.core.enableCommonFilesUser =
          cfg.enablePictures || cfg.enableMusic || cfg.enableVideo || cfg.enableIncoming;

        # Directories creation
        # -> common-files user is used by the user and its deamons
        # -> common-files group is used by several services to access the same files
        systemd.tmpfiles.rules = [
          "d ${cfg.root} 0755 root root -"
        ]
        ++ optional cfg.enableHomes "d ${cfg.homes} 0755 root root -"
        ++ optional cfg.enableCommon "d ${cfg.common} 0770 common-files users -"
        ++ optional cfg.enablePictures "d ${cfg.pictures} 0770 common-files common-files -"
        ++ optional cfg.enableMusic "d ${cfg.music} 0770 common-files common-files -"
        ++ optional cfg.enableVideo "d ${cfg.video} 0770 common-files common-files -"
        ++ optional cfg.enableIncoming "d ${cfg.incoming} 0770 common-files users -"
        ++ optional cfg.enableIncomingMusic "d ${cfg.incomingMusic} 0770 common-files users -";
      }
    )
  ];
}
