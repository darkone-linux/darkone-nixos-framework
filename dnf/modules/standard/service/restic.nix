# Restic backup module with DNF configuration.
#
# Default directories to backup:
#
# ```
# /export -> /mnt/backup/export
# <services_dirs> -> /mnt/backup/services/<services_dirs>
# <db_dumps> -> /mnt/backup/databases/<db_dumps>
# ```

{ config, lib, ... }:
let
  cfg = config.darkone.service.restic;
  srv = config.services.restic;

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
    displayOnHomepage = false;
    description = "Local backup strategy";
  };
in
{
  options = {
    darkone.service.restic.enable = lib.mkEnableOption "Enable restic backup service";
    darkone.service.restic.enableDryRun = lib.mkEnableOption "Dry Run (try)";
    # darkone.service.restic.extraBackups = lib.mkOption {
    #   type = lib.types.submodule;
    #   default = { };
    #   description = "Another services.restic.backups";
    # };
    darkone.service.restic.repositoryRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup";
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
    darkone.service.restic.enableWaitRemoteFs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Trigger the restic service only if remote-fs service is started";
    };
    darkone.service.restic.enableSystemDirsBackup = lib.mkOption {
      type = lib.types.bool;
      default = config.darkone.service.nfs.enable;
      description = "Backup the /export dir (nfs shared files)";
    };
    darkone.service.restic.systemDirsPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        dirs.homes
        dirs.common
        dirs.pictures
      ];
      description = "System dirs (exports) to include";
    };
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.restic = {
        inherit defaultParams;
        persist.dirs = [ srv.dataDir ];
        proxy.enable = false;
        #proxy.servicePort = srvPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.forgejo.enable = true;
      };

      # Restic password
      sops.secrets.restic-password = {
        mode = "0400";
        owner = "root";
      };

      # Trigger the restic service only if remote-fs service is started
      systemd.services.restic-backups-dirsbackup = lib.mkIf cfg.enableWaitRemoteFs {
        after = [ "remote-fs.target" ];
        wants = [ "remote-fs.target" ];
      };

      # Repository targets creations (initialize?)
      #systemd.tmpfiles.rules = lib.optional enableDirsBackup "d ${dirsbackup} 0700 root root -";

      # Restic service
      services.restic = {

        # TODO: voir si on utilise le rest server...
        # server = {
        #   enable = true;
        #   listenAddress = "${params.ip}:${toString srvPort}";
        # };

        backups = {
          dirsbackup = lib.mkIf enableDirsBackup {
            exclude = [
              "tmp"
              "*.tmp"
              "*~"
              ".Trash*"
              "node_modules"
              "vendor"
              ".cache"
              ".git"
            ];
            initialize = true;
            passwordFile = config.sops.secrets.restic-password.path;
            paths = cfg.systemDirsPaths;
            repository = dirsRepository;
            extraBackupArgs = lib.optionals cfg.enableDryRun [
              "--dry-run"
              "-v"
            ];
          };
        };
        # // cfg.extraBackups;
      };
    })
  ];
}
