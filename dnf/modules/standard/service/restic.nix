# Restic backup module with DNF configuration.
#
# :::tip
# Enabling "restic" in host services (config.yaml) launch the REST server.
# Put the local backup settings in nix configuration (machine conf for example).
#
# ```nix
# usr/machines/my-desktop/default.nix
# darkone.service.restic = {
#   enable = true;
#   enableSystemBackup = true;
# };
# :::
#
# Default settings:
#
# ```
# /srv/nfs/(homes|common) -> /mnt/backup/restic/[host]/srv/nfs
# /mnt/medias/(music|videos) -> /mnt/backup/restic/[host]/mnt/medias
# / -> /mnt/backup/restic/[host]/system
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

  # NFS dirs (/srv/nfs)
  inherit (config.darkone.system) srv-dirs;
  hasNfsShares = srv-dirs.enableNfs;

  # Media dirs (/srv/medias)
  hasMediasShares = srv-dirs.enableMedias;

  # Dirs backup
  nfsBackupRepo = "${cfg.repositoryRoot}/${host.hostname}${srv-dirs.nfs}";
  mediasBackupRepo = "${cfg.repositoryRoot}/${host.hostname}${srv-dirs.medias}";
  systemBackupRepo = "${cfg.repositoryRoot}/${host.hostname}/system";
  enableNfsBackup = cfg.enableNfsBackup && hasNfsShares;
  enableMediasBackup = cfg.enableMediasBackup && hasMediasShares;

  # Restic zoned password
  passwdFileName = "restic-password-" + zone.name;

  # Common backup configuration
  commonBkpConfig = {
    initialize = true; # Create the repo if needed
    runCheck = true; # Check integrity of repo before save
    passwordFile = config.sops.secrets.${passwdFileName}.path;
    environmentFile = config.sops.secrets.restic-env.path;
    timerConfig.Persistent = false;
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
      ".swapfile"
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
  srvPort = 8888;
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
    darkone.service.restic.enableSystemBackup = lib.mkEnableOption "Enable full system backup excepted /srv, /mnt and cache files";
    darkone.service.restic.enableWaitRemoteFs = lib.mkEnableOption "Trigger the restic service only if remote-fs service is started";

    # Common root repository for local backup
    darkone.service.restic.repositoryRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/restic";
      example = "rest:my-server.${zone.fqdn}:8888/${host.hostname}/";
      description = "Main backup target root path";
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

      # htpasswd
      sops.secrets.restic-htpasswd = lib.mkIf cfg.enableServer {
        mode = "0400";
        owner = "restic";
      };
      sops.secrets.restic-env = {
        mode = "0400";
        owner = "root";
      };

      # Trigger the restic service only if remote-fs service is started
      systemd.services.restic-backups-nfs = lib.mkIf cfg.enableWaitRemoteFs {
        after = [ "remote-fs.target" ];
        wants = [ "remote-fs.target" ];
      };

      # Firewall
      networking.firewall = lib.mkIf cfg.enableServer (
        lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) { allowedTCPPorts = [ srvPort ]; }
      );

      services.restic = {

        #----------------------------------------------------------------------
        # Restic REST Server
        #----------------------------------------------------------------------

        # Server
        server = lib.mkIf cfg.enableServer {
          enable = true;
          listenAddress = "${params.ip}:${toString srvPort}";
          htpasswd-file = config.sops.secrets.restic-htpasswd.path;
          dataDir = cfg.repositoryRoot;
        };

        #----------------------------------------------------------------------
        # Backups
        #----------------------------------------------------------------------

        backups = {

          # NFS
          # -> /srv/nfs/(home|common)
          nfs = lib.mkIf enableNfsBackup (
            lib.mkMerge [
              {
                paths = cfg.nfsPaths;
                repository = nfsBackupRepo;

                # https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
                timerConfig.OnCalendar = "01:00";
              }
              commonBkpConfig
            ]
          );

          # Medias
          # -> /srv/medias/(videos|music)
          medias = lib.mkIf enableMediasBackup (
            lib.mkMerge [
              {
                paths = cfg.mediasPaths;
                repository = mediasBackupRepo;
                timerConfig.OnCalendar = "03:00";
              }
              commonBkpConfig
            ]
          );

          # System
          # -> /, without /srv, /mnt and cache / log files
          system = lib.mkIf cfg.enableSystemBackup (
            lib.mkMerge [
              {
                paths = [ "/" ];
                exclude = [
                  "/dev"
                  "/etc/nixos"
                  "/export"
                  "/lib*"
                  "/mnt"
                  "/nix"
                  "/proc"
                  "/run"
                  "/srv"
                  "/sys"
                  "/tmp"
                  "/var/cache/*"
                  "/var/log/*"
                  "/var/spool/*"
                  "/var/run"
                  "/var/lock"
                ];
                repository = systemBackupRepo;
                timerConfig.OnCalendar = "04:00";
              }
              commonBkpConfig
            ]
          );
        };
      };
    })
  ];
}
