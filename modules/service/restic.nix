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

# :::note[Cloud sync folders are never backed up]
# A Nextcloud/ownCloud sync folder replicates a server-side original that is
# backed up on its own, and restic never dedups across repositories. Caught by
# path (`/home/*/Nextcloud`, numbered variants included) and by journal marker.
# :::
#
# :::caution[`listenAll` widens the bind, not the firewall]
# The server binds `params.ip`, i.e. the LAN address on a gateway. Clients
# reaching it from another zone over the tailnet need `listenAll = true`
# (bind `0.0.0.0`). The firewall stays the boundary: `lan0` gets the port from
# `getInternalInterfaceFwPath`, `tailscale0` is already a trusted interface on
# a gateway, and the WAN never opens it.
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
{
  config,
  lib,
  dnfLib,
  dnfConfig,
  network,
  zone,
  host,
  hosts,
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

  # Fleet hosts deduplicated by hostname: one REST account per hostname.
  serverHosts = lib.foldl' (
    acc: h: if lib.any (x: x.hostname == h.hostname) acc then acc else acc ++ [ h ]
  ) [ ] hosts;

  # Runtime htpasswd assembly: one bcrypt entry per fleet hostname.
  htpasswdFile = "/run/restic-rest/htpasswd";
  htpasswdLines = lib.concatStringsSep "\n" (
    lib.imap0 (
      idx: h:
      let
        pw = config.sops.secrets."restic/${h.hostname}/rest-password".path;
        flag = if idx == 0 then "-bBc" else "-bB";
      in
      ''${pkgs.apacheHttpd}/bin/htpasswd ${flag} "${htpasswdFile}" "${h.hostname}" "$(${pkgs.coreutils}/bin/cat ${pw})"''
    ) serverHosts
  );

  # Module main params (REST server bind address).
  srvPort = dnfConfig.network.ports.restic;
  defaultParams = {
    description = "Local backup strategy";
  };
  params = dnfLib.extractServiceParams host network "restic" defaultParams;

  # Backup freshness metric for Prometheus. Each backup job, on success, stamps
  # `dnf_restic_last_success_timestamp` into the node_exporter textfile
  # collector dir (same dir as monitoring.nix's maintenance flag). Only emitted
  # on monitored nodes — nowhere else would scrape it. The lib `mkResticRuleGroups`
  # turns a stale stamp into ResticBackupStale/Critical.
  textfileDir = "/var/lib/node-exporter-textfile";
  isNode = host.features ? "monitoring-node";

  # Scheme + authority of a `rest:` repository ("http://host:port"), null for a
  # local one. Matched on the final `services.restic.backups` so a job declared
  # straight by a consumer (ms-a2's `medias-lg`) is covered like the generated
  # ones.
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

  # Run as ExecStartPost: oneshot ExecStartPost only fires when the backup
  # itself succeeded, so the stamp tracks the last *successful* run. Full store
  # paths: systemd units start with an empty PATH.
  mkResticMetric =
    name:
    pkgs.writeShellScript "restic-metric-${name}" ''
      set -eu
      tmp="$(${pkgs.coreutils}/bin/mktemp "${textfileDir}/.restic-${name}.XXXXXX")"
      ${pkgs.coreutils}/bin/printf 'dnf_restic_last_success_timestamp{job="%s"} %s\n' \
        "${name}" "$(${pkgs.coreutils}/bin/date +%s)" > "$tmp"

      # mktemp creates 0600; node_exporter runs as a non-root user and must read
      # the file, so widen before the atomic rename.
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "${textfileDir}/restic-${name}.prom"
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

        # This host's REST credential (consumed by the env template below).
        # On a server, it is already declared in the all-hosts set hereafter.
        (lib.mkIf (!cfg.enableServer) {
          "restic/${host.hostname}/rest-password" = {
            mode = "0400";
            owner = "root";
          };
        })

        # Server: every fleet host's REST credential, to assemble the htpasswd.
        (lib.mkIf cfg.enableServer (
          lib.genAttrs (map (h: "restic/${h.hostname}/rest-password") serverHosts) (_: {
            mode = "0400";
            owner = "root";
          })
        ))
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
      # Ordering & firewall
      #----------------------------------------------------------------------

      # Backup-age metric: the textfile dir must exist and be writable from the
      # (hardened) backup units. Harmless on a non-node, but only useful where a
      # node_exporter scrapes it.
      systemd.tmpfiles.rules = lib.mkIf isNode [ "d ${textfileDir} 0755 root root -" ];

      # Run backups only after remote filesystems are mounted.
      systemd.services = lib.mkMerge [
        (lib.mkIf cfg.enableWaitRemoteFs (
          lib.genAttrs backupUnits (_: {
            after = [ "remote-fs.target" ];
            wants = [ "remote-fs.target" ];
          })
        ))

        # Stamp the success timestamp after each backup (see mkResticMetric).
        # ReadWritePaths punches the textfile dir through ProtectSystem.
        (lib.mkIf isNode (
          lib.listToAttrs (
            map (b: {
              name = "restic-backups-${b.name}";
              value = {
                serviceConfig.ExecStartPost = lib.mkAfter [ (mkResticMetric b.name) ];
                serviceConfig.ReadWritePaths = lib.mkAfter [ textfileDir ];
              };
            }) backupList
          )
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

        # Server: assemble the multi-user htpasswd before the REST server starts.
        # Unsandboxed oneshot so the file exists before the server's namespace
        # binds it read-only (cf. ReadOnlyPaths in the upstream unit).
        (lib.mkIf cfg.enableServer {
          restic-rest-htpasswd = {
            description = "Assemble restic REST htpasswd from per-host secrets";
            wantedBy = [ "multi-user.target" ];
            before = [ "restic-rest-server.service" ];
            requiredBy = [ "restic-rest-server.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${pkgs.coreutils}/bin/install -d -m 0750 -o restic -g restic /run/restic-rest
              ${htpasswdLines}
              ${pkgs.coreutils}/bin/chown restic:restic "${htpasswdFile}"
              ${pkgs.coreutils}/bin/chmod 0640 "${htpasswdFile}"
            '';
          };
          restic-rest-server = {
            after = [ "restic-rest-htpasswd.service" ];
            requires = [ "restic-rest-htpasswd.service" ];
          };
        })
      ];

      networking.firewall = lib.mkIf cfg.enableServer (
        lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) { allowedTCPPorts = [ srvPort ]; }
      );

      #----------------------------------------------------------------------
      # Restic service
      #----------------------------------------------------------------------

      services.restic = {

        # REST server: stores every host's repository under serverDataDir.
        server = lib.mkIf cfg.enableServer {
          enable = true;
          listenAddress = "${if cfg.listenAll then "0.0.0.0" else params.ip}:${toString srvPort}";
          dataDir = cfg.serverDataDir;
          htpasswd-file = htpasswdFile;

          # Per-host isolation: requires authenticated user == repo path prefix
          # (= hostname).
          privateRepos = true;
        };

        # Backups: generated from targets x categories.
        backups = backupAttrs;
      };
    })
  ];
}
