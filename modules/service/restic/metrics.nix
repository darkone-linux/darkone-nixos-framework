# DNF restic: backup freshness metrics, for the `dnf-restic-<zone>` alerts.
#
# Monitored nodes only (`monitoring-node` feature): each job stamps its last
# success in the textfile collector, and `restic-declared` lists the declared
# jobs so a job that never succeeds still ages into an alert.

{
  config,
  lib,
  dnfLib,
  host,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.restic;
  textfileDir = dnfLib.constants.textfileCollectorDir;
  isNode = host.features ? "monitoring-node";

  # Run as ExecStartPost: oneshot ExecStartPost only fires when the backup
  # itself succeeded, so the stamp tracks the last *successful* run. Full store
  # paths: systemd units start with an empty PATH.
  mkResticMetric =
    name:
    pkgs.writeShellScript "restic-metric-${name}" ''
      set -eu
      tmp="$(${pkgs.coreutils}/bin/mktemp "${textfileDir}/.restic-${name}.XXXXXX")"

      # `backup`, not `job`: the scrape owns `job`, an exported one comes back
      # as `exported_job` and the alert rules can no longer tell jobs apart.
      ${pkgs.coreutils}/bin/printf 'dnf_restic_last_success_timestamp{backup="%s"} %s\n' \
        "${name}" "$(${pkgs.coreutils}/bin/date +%s)" > "$tmp"

      # mktemp creates 0600; node_exporter runs as a non-root user and must read
      # the file, so widen before the atomic rename.
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "${textfileDir}/restic-${name}.prom"
    '';

  # Declared-jobs list: epoch each job was first seen on this host. The rules
  # fall back to it while a job has no success stamp, so a job that never
  # succeeds still ages into ResticBackupStale/Critical.
  resticDeclared = pkgs.writeShellScript "restic-declared" ''
    set -eu
    names=${lib.escapeShellArg (lib.concatStringsSep " " (builtins.attrNames config.services.restic.backups))}
    out="${textfileDir}/restic.prom"
    now="$(${pkgs.coreutils}/bin/date +%s)"
    tmp="$(${pkgs.coreutils}/bin/mktemp "${textfileDir}/.restic.XXXXXX")"
    for name in $names; do

      # First-seen epoch from the previous run, else now: a reboot or a switch
      # must not restart the grace period.
      key="dnf_restic_declared_timestamp{backup=\"$name\"}"
      since="$(${pkgs.gawk}/bin/awk -v k="$key" '$1 == k { print $2; exit }' "$out" 2>/dev/null || true)"
      ${pkgs.coreutils}/bin/printf '%s %s\n' "$key" "''${since:-$now}" >> "$tmp"
    done

    # Same world-readable atomic write as mkResticMetric.
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$out"

    # A removed job's success stamp never refreshes: Stale/Critical would fire
    # forever. The `restic-*` glob never matches `restic.prom`.
    for f in "${textfileDir}"/restic-*.prom; do
      [ -e "$f" ] || continue
      name="''${f##*/restic-}"
      name="''${name%.prom}"
      case " $names " in
        *" $name "*) ;;
        *) ${pkgs.coreutils}/bin/rm -f "$f" ;;
      esac
    done
  '';
in
{
  config = lib.mkIf (cfg.enable && isNode) {

    # The textfile dir must exist and be writable from the hardened units.
    systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];

    systemd.services = lib.mkMerge [

      # Stamp the success timestamp after each backup (see mkResticMetric).
      # Merged backup set, so a hand-declared job is watched like a generated
      # one. ReadWritePaths punches the textfile dir through ProtectSystem.
      (lib.mapAttrs' (
        name: _:
        lib.nameValuePair "restic-backups-${name}" {
          serviceConfig.ExecStartPost = lib.mkAfter [ (mkResticMetric name) ];
          serviceConfig.ReadWritePaths = lib.mkAfter [ textfileDir ];
        }
      ) config.services.restic.backups)

      # Declared-jobs list and orphan cleanup (see resticDeclared). Names are
      # baked into the script: a changed list changes the unit, RemainAfterExit
      # keeps it active so the switch restarts it.
      {
        restic-declared = {
          description = "Export declared restic jobs, drop stamps of removed ones";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = resticDeclared;
          };
        };
      }
    ];
  };
}
