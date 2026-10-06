# Restic backup module: REST server + per-host backup targets.
#
# :::tip[Two roles, one module]
# - Server: a host with `restic` in its config.yaml services runs the REST
#   server (`enableServer`) and stores every host's repository.
# - Client: any host with `enable = true` declares backup `targets`
#   (local path or `rest:http://restic.<zone>:<port>`).
# :::
#
# :::note[Two passwords, do not confuse]
# - Repository passphrase: `restic-password-<zone>`, encrypts the repo content.
# - REST credential: per-host `restic/<hostname>/rest-password`, authenticates
#   the host against the REST server.
#
# Both are created by `just configure-admin-host` (idempotent), which reads
# the fleet's declared hosts and zones.
# :::
#
# Example (machine config):
#
# ```nix
# darkone.service.restic = {
#   enable = true;
#   targets = [
#     { name = "main"; root = "rest:http://restic.my-zone.my-domain.tld:8888";
#       zone = "ag"; categories = [ "system" "nfs" ]; }
#   ];
# };
# ```
#
# Repository layout per target: one repo per category, named after it.
#
# ```
# <root>/<hostname>/system  <- "system" category (/ minus excludes)
# <root>/<hostname>/nfs     <- "nfs" category    (/srv/nfs/<...>)
# <root>/<hostname>/medias  <- "medias" category (/srv/medias/<...>)
# ```
#
# :::caution[Repo path is exactly two levels deep]
# rest-server serves repositories at most two components below its `--path`:
# `<hostname>/medias` answers, `<hostname>/srv/medias` returns 404 and restic
# reports a misleading `repository does not exist`. The subpath is therefore
# the bare category name, never the source directory. Identical layout for
# local and REST targets lets a repo move between the two without a rename.
# :::
#
# :::note[An unreachable REST server skips the run]
# Every `rest:` target carries an `ExecCondition` reachability probe. A backup
# whose server is down is *skipped*, never failed: no nightly
# SystemdUnitFailed, no quarter-hour of restic retries, and no `initialize`
# creating an empty repo against a dead endpoint. The missing backup still
# surfaces, through ResticBackupStale / ResticBackupCritical, which watch the
# last successful run.
# :::
#
# :::note[Cloud sync folders are never backed up]
# A Nextcloud/ownCloud sync folder replicates a server-side original that is
# backed up on its own, and restic never dedups across repositories. Caught by
# path (`/home/*/Nextcloud`, numbered variants included) and by journal marker.
# :::
#
# :::danger[Migrating repos created before this layout]
# Repos written when the subpath mirrored the source directory sit under
# `<hostname>/srv/{nfs,medias}`. Rename them on the server before the next run:
# `initialize = true` would otherwise create an empty repo at the new path and
# silently start a full re-seed.
#
# ```sh
# mv <data-dir>/<hostname>/srv/medias <data-dir>/<hostname>/medias
# rmdir <data-dir>/<hostname>/srv
# ```
# :::
#
# Sub-modules (`restic/`):
# - `server.nix`: the REST server, one account per fleet host;
# - `metrics.nix`: backup freshness metrics for the restic alerts.
#
# #### REST server (`server.nix`)
#
# One account per fleet host (`restic/<hostname>/rest-password`), checked
# against an htpasswd assembled at boot; `privateRepos` confines each host to
# its own `<hostname>/` prefix.
#
# :::caution[`listenAll` widens the bind, not the firewall]
# The server binds `params.ip`, i.e. the LAN address on a gateway. Clients
# reaching it from another zone over the tailnet need `listenAll = true`
# (bind `0.0.0.0`). The firewall stays the boundary: `lan0` gets the port from
# `getInternalInterfaceFwPath`, `tailscale0` is already a trusted interface on
# a gateway, and the WAN never opens it.
# :::
#
# #### Metrics (`metrics.nix`)
#
# Monitored nodes only (`monitoring-node` feature): each job stamps its last
# success in the textfile collector, and `restic-declared` lists the declared
# jobs so a job that never succeeds still ages into a `dnf-restic-<zone>`
# alert.

{
  config,
  lib,
  dnfLib,
  dnfConfig,
  network,
  zone,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.restic;
  srv = config.services.restic.server;

  # Shared directories (/srv/nfs, /srv/medias) and their availability.
  inherit (config.darkone.system) srv-dirs;

  # Stagger the timers of several targets sharing the same base time.
  inherit (dnfLib) shiftHour;

  # Common options shared by every backup job.
  commonBkpConfig = {

    # Create the repo if needed, check its integrity before saving.
    initialize = true;
    runCheck = true;

    # REST credential (username + password), unused for local repositories.
    environmentFile = config.sops.templates."restic-rest-env".path;
    timerConfig.Persistent = false;

    # Cloud sync replicas: the server-side original is backed up already, and
    # restic never dedups across repositories. Legacy folders only — client 34
    # dropped SyncRunFileLog, and the `.sync_<hash>.db` it still writes is out
    # of reach of `--exclude-if-present`, which matches literally.
    extraBackupArgs = [
      "--exclude-if-present"
      ".nextcloudsync.log"
      "--exclude-if-present"
      ".owncloudsync.log"
    ]
    ++ lib.optionals cfg.enableDryRun [
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
      ".~*"
      "node_modules"
      "vendor"
      ".cache"
      "cache/*"
    ];

    # https://restic.readthedocs.io/en/stable/060_forget.html#removing-snapshots-according-to-a-policy
    pruneOpts = [
      "--keep-last 24" # Last 24 snapshots
      "--keep-hourly 24" # One per hour for 24 hours
      "--keep-daily 7" # One per day for 7 days
      "--keep-weekly 8" # One per week for 8 weeks
      "--keep-monthly 24" # One per month for 24 months
      "--keep-yearly 75" # One per year for 75 years
    ];
  };

  # Specific options for the "system" category (full root, minus volatile data
  # and cloud replicas).
  systemBkpConfig = {
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
      "/var/lib/immich/thumbs/*"
      "/var/lib/immich/encoded-video/*"

      # Specific home paths
      "/home/*/src" # projects sources (git)
      "/home/*/backups" # local backups

      # Cloud sync folders, caught by path: a current client writes none of the
      # markers above. `[0-9]*` — it numbers the folder when ~/Nextcloud
      # already exists.
      "/home/*/Nextcloud"
      "/home/*/Nextcloud[0-9]*"
    ];
  };

  # Per-category metadata: default time, paths and prerequisite. The repo
  # subpath is the category name itself (cf. header): unique by construction,
  # and independent of where the data actually lives on disk.
  categoryMeta = {
    system = {
      baseTime = "01:00";
      extra = systemBkpConfig;
      prereq = true;
    };
    nfs = {
      baseTime = "03:00";
      extra = {
        paths = cfg.nfsPaths;
      };
      prereq = srv-dirs.enableNfs;
    };
    medias = {
      baseTime = "05:00";
      extra = {
        paths = cfg.mediasPaths;
      };
      prereq = srv-dirs.enableMedias;
    };
  };

  # Build one `services.restic.backups.<name>` entry for a target/category.
  # `idx` is the target rank, used to stagger same-category timers.
  mkBackup = idx: target: category: {
    name = "${category}-${target.name}";
    value = lib.mkMerge [
      (
        categoryMeta.${category}.extra
        // {
          repository = "${target.root}/${host.hostname}/${category}";
          passwordFile = config.sops.secrets."restic-password-${target.zone}".path;
          timerConfig.OnCalendar = shiftHour categoryMeta.${category}.baseTime idx;
        }
      )
      commonBkpConfig
    ];
  };

  # Flatten targets x (enabled) categories into backup entries.
  backupList = lib.flatten (
    lib.imap0 (
      idx: target:
      map (mkBackup idx target) (lib.filter (cat: categoryMeta.${cat}.prereq) target.categories)
    ) cfg.targets
  );
  backupAttrs = builtins.listToAttrs backupList;
  backupUnits = map (b: "restic-backups-${b.name}") backupList;

  # Zones whose repository passphrase must be available on this host (one per
  # target zone). A host-specific backup referencing another zone passphrase
  # must add a matching target zone.
  referencedZones = lib.unique (lib.filter (z: z != "") (map (t: t.zone) cfg.targets));

  # Module main params (REST server bind address).
  srvPort = dnfConfig.network.ports.restic;
  defaultParams = {
    description = "Local backup strategy";
  };
  params = dnfLib.extractServiceParams host network "restic" defaultParams;

  # Scheme + authority of a `rest:` repository ("http://host:port"), null for a
  # local one. Matched on the final `services.restic.backups`: a job declared
  # by the consumer itself is covered like the generated ones.
  restEndpoint =
    repository:
    let
      m = builtins.match "rest:(https?://[^/]+).*" repository;
    in
    if m == null then null else builtins.head m;

  # ExecCondition probe: exit 1 makes systemd skip the unit instead of failing
  # it. curl covers both outages seen in production — the name no longer
  # resolves (the off-site zone resolver died with its gateway) and the port no
  # longer answers. A 401 from the REST server counts as reachable, which is
  # exactly what we ask.
  resticReachable = pkgs.writeShellScript "restic-reachable" ''
    ${pkgs.curl}/bin/curl --silent --show-error --output /dev/null \
      --connect-timeout 5 --max-time 15 "$1" || exit 1
  '';
in
{
  options = {

    #------------------------------------------------------------------------
    # General
    #------------------------------------------------------------------------

    darkone.service.restic.enable = lib.mkEnableOption "Enable restic backup client";
    darkone.service.restic.enableDryRun = lib.mkEnableOption "Dry Run mode";
    darkone.service.restic.enableWaitRemoteFs = lib.mkEnableOption "Run backups only after remote-fs.target";

    #------------------------------------------------------------------------
    # REST server
    #------------------------------------------------------------------------

    darkone.service.restic.enableServer = lib.mkEnableOption "Enable restic REST server";
    darkone.service.restic.listenAll = lib.mkEnableOption "Bind the REST server on 0.0.0.0 (off-site clients)";
    darkone.service.restic.serverDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backup/restic";
      description = "Local storage root of the REST server (all hosts' repos)";
    };

    #------------------------------------------------------------------------
    # Backup targets
    #------------------------------------------------------------------------

    darkone.service.restic.targets = lib.mkOption {
      description = "Backup destinations for this host (local path or REST URL)";
      default = [ ];
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              default = "main";
              description = "Target id, used in backup/unit names (<category>-<name>)";
            };
            root = lib.mkOption {
              type = lib.types.str;
              default = "/mnt/backup/restic";
              example = "rest:http://restic.${zone.domain}:${toString srvPort}";
              description = "Repository root: local path or REST URL";
            };
            zone = lib.mkOption {
              type = lib.types.str;
              default = zone.name;
              description = "Zone selecting the repo passphrase (restic-password-<zone>)";
            };
            categories = lib.mkOption {
              type = lib.types.listOf (
                lib.types.enum [
                  "system"
                  "nfs"
                  "medias"
                ]
              );
              default = [ "system" ];
              description = "What to back up to this target";
            };
          };
        }
      );
    };

    #------------------------------------------------------------------------
    # Paths
    #------------------------------------------------------------------------

    darkone.service.restic.nfsPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        srv-dirs.homes
        srv-dirs.common
      ];
      description = "NFS dirs (/srv/nfs/<xxx>) included in the 'nfs' category";
    };
    darkone.service.restic.mediasPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        srv-dirs.music
        srv-dirs.videos
      ];
      description = "Medias dirs (/srv/medias/<xxx>) included in the 'medias' category";
    };

    # Values shared with the `restic/` sub-modules.
    darkone.service.restic.shared = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = { inherit params; };
      defaultText = "computed";
      description = "Restic values shared with the `restic/` sub-modules.";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF service registration
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
      darkone.system.services = dnfLib.enableBlock "restic";

      #----------------------------------------------------------------------
      # Dependencies & secrets
      #----------------------------------------------------------------------

      environment.systemPackages = [ pkgs.restic ];

      sops.secrets = lib.mkMerge [

        # Repository passphrases for every referenced zone.
        (lib.genAttrs (map (z: "restic-password-${z}") referencedZones) (_: {
          mode = "0400";
          owner = "root";
        }))

        # This host's REST credential (consumed by the env template below). A
        # server declares it along with every host's (`restic/server.nix`).
        (lib.mkIf (!cfg.enableServer) {
          "restic/${host.hostname}/rest-password" = {
            mode = "0400";
            owner = "root";
          };
        })
      ];

      # REST environment: declarative username + per-host password. Harmless for
      # local targets (variables simply unused; encryption uses passwordFile).
      sops.templates."restic-rest-env" = {
        owner = "root";
        content = ''
          RESTIC_REST_USERNAME=${host.hostname}
          RESTIC_REST_PASSWORD=${config.sops.placeholder."restic/${host.hostname}/rest-password"}
        '';
      };

      #----------------------------------------------------------------------
      # Ordering
      #----------------------------------------------------------------------

      # Run backups only after remote filesystems are mounted.
      systemd.services = lib.mkMerge [
        (lib.mkIf cfg.enableWaitRemoteFs (
          lib.genAttrs backupUnits (_: {
            after = [ "remote-fs.target" ];
            wants = [ "remote-fs.target" ];
          })
        ))

        # Remote targets: an off-site server that is down must skip the run,
        # not fail it (cf. the header note). Matched on the merged backup set
        # so consumer-declared jobs are covered too.
        (lib.mapAttrs' (
          name: b:
          lib.nameValuePair "restic-backups-${name}" {
            serviceConfig.ExecCondition = [ "${resticReachable} ${restEndpoint b.repository}" ];
          }
        ) (lib.filterAttrs (_: b: restEndpoint b.repository != null) config.services.restic.backups))
      ];

      #----------------------------------------------------------------------
      # Restic service
      #----------------------------------------------------------------------

      # Backups: generated from targets x categories.
      services.restic.backups = backupAttrs;
    })
  ];
}
