# Restic backup module with DNF configuration.
#
# Default directories to backup:
#
# ```
# /srv/nfs -> /mnt/backup/restic/srv/nfs
# <services_dirs> -> /mnt/backup/services/<services_dirs>
# <db_dumps> -> /mnt/backup/databases/<db_dumps>
# ```

# TODO: sauvegarde via rest + voir si sauvegarde tout /var ou /var/lib plutôt que des petites parties...
{
  config,
  lib,
  dnfLib,
  network,
  zone,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.restic;
  srv = config.services.restic.server;
  bkps = config.services.restic.backups;

  # NFS dirs (/srv/nfs)
  inherit (config.darkone.system) srv-dirs;
  hasNfsShares = srv-dirs.enableNfs;

  # Media dirs (/srv/medias)
  hasMediasShares = srv-dirs.enableMedias;

  # Dirs backup
  nfsBackupRepo = "${cfg.repositoryRoot}${srv-dirs.nfs}";
  mediasBackupRepo = "${cfg.repositoryRoot}${srv-dirs.medias}";
  servicesBackupRepo = "${cfg.repositoryRoot}/services";
  enableNfsBackup = cfg.enableNfsBackup && hasNfsShares;
  enableMediasBackup = cfg.enableMediasBackup && hasMediasShares;

  # Restic zoned password
  passwdFileName = "restic-password-" + zone.name;

  # Common backup configuration
  commonBkpConfig = {
    initialize = true; # Create the repo if needed
    runCheck = true; # Check integrity of repo before save
    passwordFile = config.sops.secrets.${passwdFileName}.path;
    extraBackupArgs = lib.optionals cfg.enableDryRun [
      "--dry-run"
      "-v"
    ];

    exclude = [
      "tmp"
      "*.tmp"
      "*~"
      "*.log"
      ".Trash*"
      "node_modules"
      "vendor"
      ".cache"
      "cache/*"
    ];

    # https://restic.readthedocs.io/en/stable/060_forget.html#removing-snapshots-according-to-a-policy
    pruneOpts = [
      # On conserve...
      "--keep-last 24" # Les 24 derniers snapshots
      "--keep-hourly 24" # Un par heure pendant 24 heures (le plus récent de chaque heure)
      "--keep-daily 7" # Un par jour pendant 7 jours
      "--keep-weekly 8" # Un par semaine pendant 8 semaines
      "--keep-monthly 24" # Un par mois pendant 24 mois
      "--keep-yearly 75" # Un par an pendant 75 ans
    ];
  };

  # Module main params
  srvPort = 8081;
  defaultParams = {
    description = "Local backup strategy";
  };
  params = dnfLib.extractServiceParams host network "restic" defaultParams;
in
{
  options = {

    #------------------------------------------------------------------------
    # Options
    #------------------------------------------------------------------------

    # General options
    darkone.service.restic.enable = lib.mkEnableOption "Enable main restic backup service";
    darkone.service.restic.enableServer = lib.mkEnableOption "Enable restic rest server";
    darkone.service.restic.enableDryRun = lib.mkEnableOption "Dry Run mode";
    darkone.service.restic.enableWaitRemoteFs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Trigger the restic service only if remote-fs service is started";
    };
    darkone.service.restic.repositoryRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/restic/${host.hostname}";
      example = "rest:nix@backup.${zone.domain}:/mnt/backup/restic/${host.hostname}";
      description = "Main backup target root path";
    };

    # Services options
    darkone.service.restic.enableServicesBackup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Backup important files of local services (persist dirs)";
    };
    darkone.service.restic.enableServicesVarBackup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Backup variable files of local services (persist varDirs)";
    };

    # NFS options
    darkone.service.restic.enableNfsBackup = lib.mkOption {
      type = lib.types.bool;
      default = config.darkone.service.nfs.enable;
      description = "Backup /srv/nfs/<xxx> dirs";
    };
    darkone.service.restic.nfsPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        srv-dirs.homes
        srv-dirs.common
      ];
      description = "NFS dirs (/srv/nfs/<xxx>) to include in backup configuration";
    };

    # Medias options
    darkone.service.restic.enableMediasBackup = lib.mkOption {
      type = lib.types.bool;
      default = config.darkone.service.jellyfin.enable;
      description = "Backup /srv/medias/<xxx> dirs";
    };
    darkone.service.restic.mediasPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        srv-dirs.music
        srv-dirs.videos
      ];
      description = "NFS dirs (/srv/medias/<xxx>) to include in backup configuration";
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

      # Restic executable
      environment.systemPackages = with pkgs; [ restic ];

      # Restic password
      sops.secrets.${passwdFileName} = {
        mode = "0400";
        owner = "root";
      };

      # Trigger the restic service only if remote-fs service is started
      systemd.services.restic-backups-nfsbackup = lib.mkIf cfg.enableWaitRemoteFs {
        after = [ "remote-fs.target" ];
        wants = [ "remote-fs.target" ];
      };

      #------------------------------------------------------------------------
      # Restic Service
      #------------------------------------------------------------------------

      services.restic = {

        # Restic REST server
        server = lib.mkIf cfg.enableServer {
          enable = true;
          listenAddress = "${params.ip}:${toString srvPort}";
        };

        #----------------------------------------------------------------------
        # Backups
        #----------------------------------------------------------------------

        backups = {

          # NFS
          # -> /srv/nfs/(home|common)
          nfsbackup = lib.mkIf enableNfsBackup (
            lib.mkMerge [
              {
                paths = cfg.nfsPaths;
                repository = nfsBackupRepo;

                # https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
                timerConfig = {
                  OnCalendar = "01:00";
                  Persistent = false;
                };
              }
              commonBkpConfig
            ]
          );

          # Medias
          # -> /srv/medias/(videos|music)
          mediasbackup = lib.mkIf enableMediasBackup (
            lib.mkMerge [
              {
                paths = cfg.mediasPaths;
                repository = mediasBackupRepo;
                timerConfig = {
                  OnCalendar = "04:00";
                  Persistent = false;
                };
              }
              commonBkpConfig
            ]
          );

          # Services
          # -> All "persist" dirs of local enabled services except var (files, databases, medias)
          servicesbackup =
            let
              alreadyBackupedPaths =
                (lib.optionals (lib.hasAttrByPath [ "nfsbackup" "paths" ] bkps) bkps.nfsbackup.paths)
                ++ (lib.optionals (lib.hasAttrByPath [ "mediasbackup" "paths" ] bkps) bkps.mediasbackup.paths);
            in
            lib.mkIf cfg.enableServicesBackup (
              lib.mkMerge [
                {
                  paths = lib.subtractLists alreadyBackupedPaths (
                    lib.unique (
                      lib.concatLists (
                        lib.mapAttrsToList (_: s: s.persist.dirs ++ s.persist.dbDirs ++ s.persist.mediaDirs) (
                          lib.filterAttrs (_: s: s.enable) config.darkone.system.services.service
                        )
                      )
                    )
                  );
                  exclude = alreadyBackupedPaths;
                  repository = servicesBackupRepo;
                  timerConfig = {
                    OnCalendar = "05:00";
                    Persistent = false;
                  };
                }
                commonBkpConfig
              ]
            );

          # Variable files (services)
          # -> All "persist" dirs of local enabled services except var (files, databases, medias)
          servicesvarbackup = lib.mkIf cfg.enableServicesVarBackup (
            lib.mkMerge [
              {
                paths = lib.unique (
                  lib.concatLists (
                    lib.mapAttrsToList (_: s: s.persist.varDirs) (
                      lib.filterAttrs (_: s: s.enable) config.darkone.system.services.service
                    )
                  )
                );
                repository = servicesBackupRepo;
                timerConfig = {
                  OnCalendar = "06:00";
                  Persistent = false;
                };
              }
              commonBkpConfig
            ]
          );
        };
      };
    })
  ];
}
