# Borg backup module with DNF configuration.
#
# Default directories to backup:
#
# ```
# /srv -> /mnt/backup/borg/srv
# <services_dirs> -> /mnt/backup/borg/services/
# <db_dumps> -> /mnt/backup/borg/databases/
# ```
#
# :::note
# The officially selected solution is Restic, which will be more appropriate and integrated with DNF.
# If you prefer borg, this module is still operational.
# :::

{ config, lib, ... }:
let
  cfg = config.darkone.service.borg;

  # Dirs (exports)
  inherit (config.darkone.system) dirs;
  hasExport =
    dirs.enableHomes # TODO -> factoriser avec la même condition dans "dirs"
    || dirs.enableCommon
    || dirs.enablePictures
    || dirs.enableMusic
    || dirs.enableVideo
    || dirs.enableIncoming
    || dirs.enableIncomingMusic;

  # Dirs backup
  dirsRepository = "${cfg.repositoryRoot}${dirs.root}";
  enableDirsBackup = cfg.enableSystemDirsBackup && hasExport;

  # Module main params
  #srvPort = 8081;
  defaultParams = {
    description = "Local backup strategy";
  };
in
{
  options = {
    darkone.service.borg.enable = lib.mkEnableOption "Enable borg backup service";
    darkone.service.borg.enableDryRun = lib.mkEnableOption "Dry Run (try)";
    # darkone.service.borg.extraBackups = lib.mkOption {
    #   type = lib.types.submodule;
    #   default = { };
    #   description = "Another services.borg.backups";
    # };
    darkone.service.borg.repositoryRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/borg";
      description = "Main backup target root path";
    };
    darkone.service.borg.enableServicesBackup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Backup important files of local services (wip)";
    };
    darkone.service.borg.enableDatabasesBackup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Backup local services databases (wip)";
    };
    darkone.service.borg.enableWaitRemoteFs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Trigger the borg service only if remote-fs service is started";
    };
    darkone.service.borg.enableSystemDirsBackup = lib.mkOption {
      type = lib.types.bool;
      default = config.darkone.service.nfs.enable;
      description = "Backup the /export dir (nfs shared files)";
    };
    darkone.service.borg.systemDirsPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        dirs.homes
        dirs.common
        #dirs.pictures
      ];
      description = "System dirs (exports) to include";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.borg = {
        inherit defaultParams;
        displayOnHomepage = false;
        proxy.enable = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.forgejo.enable = true;
      };

      #------------------------------------------------------------------------
      # Borg service dependencies & configuration
      #------------------------------------------------------------------------

      # Borg password
      sops.secrets.borg-password = {
        mode = "0400";
        owner = "root";
      };

      # Trigger the borg service only if remote-fs service is started
      systemd.services.borg-backups-dirsbackup = lib.mkIf cfg.enableWaitRemoteFs {
        after = [ "remote-fs.target" ];
        wants = [ "remote-fs.target" ];
      };

      # Repository targets creations (initialize?)
      #systemd.tmpfiles.rules = lib.optional enableDirsBackup "d ${dirsbackup} 0700 root root -";

      #------------------------------------------------------------------------
      # Borg Repos
      #------------------------------------------------------------------------

      #services.borgbackup.repos.main = lib.mkIf enableDirsBackup { path = dirsRepository; };

      #------------------------------------------------------------------------
      # Borg Jobs
      #------------------------------------------------------------------------

      services.borgbackup.jobs.dirsbackup = lib.mkIf enableDirsBackup {
        doInit = true;
        repo = dirsRepository;
        paths = cfg.systemDirsPaths;
        startAt = "daily";
        exclude = [
          "tmp"
          "*.tmp"
          "*~"
          "*.log"
          ".Trash*"
          "node_modules"
          "vendor"
          ".cache"
        ];
        prune.keep = {
          within = "1d"; # Keep all archives from the last day
          daily = 7;
          weekly = 4;
          monthly = -1; # Keep at least one archive for each month
        };
        inhibitsSleep = true; # Empêche le client de s'endormir.
        removableDevice = true;
        persistentTimer = true;
        encryption = {
          mode = "repokey-blake2";
          passCommand = "cat " + config.sops.secrets.borg-password.path;
        };
        # patterns = []; # Certainement utile pour la sauvegarde des services.
        # compression = "lz4"; # Voir si on peut optimiser avec ça.
        # readWritePaths = []; # Liste des chemins dans lesquels borg peut écrire (dump db, etc.).
      };
    })
  ];
}
