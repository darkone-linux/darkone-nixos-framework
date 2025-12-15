# Restic backup module with DNF configuration.
#
# Default directories to backup:
#
# ```
# /srv/nfs -> /mnt/backup/restic/srv/nfs
# <services_dirs> -> /mnt/backup/services/<services_dirs>
# <db_dumps> -> /mnt/backup/databases/<db_dumps>
# ```

{ config, lib, ... }:
let
  cfg = config.darkone.service.restic;
  srv = config.services.restic;

  # Dirs (exports)
  inherit (config.darkone.system) srv-dirs;
  hasNfsShares = srv-dirs.enableNfs;

  # Dirs backup
  nfsBackupRepo = "${cfg.repositoryRoot}${srv-dirs.nfs}";
  enableNfsBackup = cfg.enableNfsBackup && hasNfsShares;

  # Module main params
  #srvPort = 8081;
  defaultParams = {
    description = "Local backup strategy";
  };
in
{
  options = {
    darkone.service.restic.enable = lib.mkEnableOption "Enable restic backup service";
    darkone.service.restic.enableDryRun = lib.mkEnableOption "Dry Run mode";
    darkone.service.restic.enableWaitRemoteFs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Trigger the restic service only if remote-fs service is started";
    };
    darkone.service.restic.repositoryRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/restic";
      description = "Main backup target root path";
    };
    darkone.service.restic.enableServicesBackup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Backup important files of local services (wip)";
    };
    darkone.service.restic.enableDatabasesBackup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Backup local services databases (wip)";
    };
    darkone.service.restic.enableNfsBackup = lib.mkOption {
      type = lib.types.bool;
      default = config.darkone.service.nfs.enable;
      description = "Backup /srv/nfs/<xxx> dirs (services important files)";
    };
    darkone.service.restic.nfsDirsPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        srv-dirs.homes
        srv-dirs.common
      ];
      description = "NFS dirs (/srv/nfs/<xxx>) to include in backup configuration";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.restic = {
        inherit defaultParams;
        displayOnHomepage = false;
        persist.dirs = [ srv.dataDir ];
        proxy.enable = false;
        #proxy.servicePort = srvPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.restic.enable = true;
      };

      #------------------------------------------------------------------------
      # Restic service dependencies & configuration
      #------------------------------------------------------------------------

      # Restic password
      sops.secrets.restic-password = {
        mode = "0400";
        owner = "root";
      };

      # Trigger the restic service only if remote-fs service is started
      systemd.services.restic-backups-nfsbackup = lib.mkIf cfg.enableWaitRemoteFs {
        after = [ "remote-fs.target" ];
        wants = [ "remote-fs.target" ];
      };

      # Repository targets creations (initialize?)
      #systemd.tmpfiles.rules = lib.optional enableNfsBackup "d ${dirsbackup} 0700 root root -";

      #------------------------------------------------------------------------
      # Restic Service
      #------------------------------------------------------------------------

      services.restic = {

        # TODO: voir si on utilise le rest server...
        # server = {
        #   enable = true;
        #   listenAddress = "${params.ip}:${toString srvPort}";
        # };

        backups = {
          nfsbackup = lib.mkIf enableNfsBackup {
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
            initialize = true; # Create the repo if needed
            runCheck = true; # Check integrity of repo before save
            passwordFile = config.sops.secrets.restic-password.path;
            paths = cfg.nfsDirsPaths;
            repository = nfsBackupRepo;
            extraBackupArgs = lib.optionals cfg.enableDryRun [
              "--dry-run"
              "-v"
            ];

            # https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
            timerConfig = {
              OnCalendar = "daily";
              Persistent = false;
            };

            # https://restic.readthedocs.io/en/stable/060_forget.html#removing-snapshots-according-to-a-policy
            pruneOpts = [
              "--keep-last 24"
              "--keep-hourly 24"
              "--keep-daily 7"
              "--keep-weekly 5"
              "--keep-monthly 12"
              "--keep-yearly 75"
            ];
          };
        };
        # // cfg.extraBackups;
      };
    })
  ];
}
