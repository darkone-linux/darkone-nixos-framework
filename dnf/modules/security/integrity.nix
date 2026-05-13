# Filesystem integrity — HIDS (R76–R77). (wip)
#
# Covers sealing and integrity verification via AIDE (R76) and protection
# of the sealed database with GPG signature plus remote copy (R77).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R76 — AIDE]
# A full scan can take 15–60 min depending on FS size and CPU.
# Schedule during off-peak hours. Frequent false positives on /etc/resolv.conf,
# /var/lib, /var/cache — add them to exclusions.
# :::
#
# :::caution[R77 — Signed database]
# The AIDE database must be re-signed at every major NixOS update
# (the store changes). Plan a baseline update procedure.
# :::

{
  lib,
  dnfLib,
  config,
  pkgs,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.integrity;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.integrity.enable = lib.mkEnableOption "Enable ANSSI HIDS integrity — AIDE (R76–R77).";

    darkone.security.integrity.aideRemoteCopy = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            host = lib.mkOption {
              type = lib.types.str;
              description = "Remote host for the AIDE database copy.";
            };
            sshKeyFile = lib.mkOption {
              type = lib.types.path;
              description = "Path to the private SSH key for the remote copy.";
            };
          };
        }
      );
      default = null;
      description = "Remote copy of the GPG-signed AIDE database (R77). null = disabled.";
    };
  };

  config = lib.mkMerge [
    { darkone.security.integrity.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R76 — Seal / verify integrity (high, base, tag: no-sealing)
        # sideEffects: long scan (15-60 min), heavy I/O, false positives on /etc/resolv.conf
        (lib.mkIf (isActive "R76" "high" "base" [ "no-sealing" ]) {

          # TODO: this service does not exist — either create it, or install AIDE and define the config...
          # services.aide = {
          #   enable = true;

          #   # AIDE configuration: monitor critical paths
          #   # On NixOS: /run/current-system/sw rather than /usr (link to immutable store)
          #   settings = ''
          #     # Default policy
          #     ALLXTRAHASHES = sha512+rmd160+sha256

          #     # Paths to monitor
          #     /etc          ALLXTRAHASHES
          #     /boot         ALLXTRAHASHES
          #     /run/current-system/sw ALLXTRAHASHES

          #     # NixOS exclusions
          #     !/var/log
          #     !/var/lib
          #     !/var/cache
          #     !/proc
          #     !/sys
          #     !/run
          #     !/etc/resolv.conf
          #     !/etc/machine-id
          #   '';
          # };

          # Daily verification timer
          systemd.timers.aide-check = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = "daily";
              RandomizedDelaySec = "1h"; # Random offset to avoid simultaneous load
              Persistent = true;
            };
          };
          systemd.services.aide-check = {
            description = "ANSSI R76: AIDE integrity check";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.aide}/bin/aide --config=/etc/aide/aide.conf --check";

              # Run during off-peak hours (2-4am)
              IOSchedulingClass = "idle";
              CPUSchedulingPolicy = "idle";
            };
          };
        })

        # R77 — Protect the sealed database (high, base)
        # sideEffects: signature procedure required at every update
        (lib.mkIf (isActive "R77" "high" "base" [ "no-sealing" ]) {

          # Restrictive permissions on the AIDE database
          systemd.tmpfiles.rules = [
            "d /var/lib/aide 0700 root root -"
            "z /var/lib/aide/aide.db.gz 0600 root root -"
          ];

          # Remote copy of the database if configured
          systemd.services.aide-remote-backup = lib.mkIf (cfg.aideRemoteCopy != null) {
            description = "ANSSI R77: remote copy of the AIDE database";
            after = [ "aide-check.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = pkgs.writeShellScript "aide-remote-backup" ''
                scp -i ${cfg.aideRemoteCopy.sshKeyFile} \
                  /var/lib/aide/aide.db.gz \
                  ${cfg.aideRemoteCopy.host}:/var/backups/aide/$(hostname)-$(date +%Y%m%d).db.gz
              '';
            };
          };

          # TODO: GPG signature of the database (offline key recommended)
        })
      ]
    ))
  ];
}
