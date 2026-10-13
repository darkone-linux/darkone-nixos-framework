# DNF monitoring: rw mounts the kernel turned read-only. Doc: `../monitoring.nix` header.

{
  config,
  lib,
  dnfLib,
  pkgs,
  ...
}:
let
  inherit (config.darkone.service.monitoring) isNode;

  # tmpfs, not `textfileCollectorDir`: where /var/lib sits on the failing
  # filesystem, the file could no longer be rewritten and would keep reporting
  # the last healthy state.
  runDir = dnfLib.constants.textfileRuntimeDir;

  exportForcedReadonly = pkgs.writeShellScript "dnf-fs-readonly" ''
    set -eu
    tmp="$(${pkgs.coreutils}/bin/mktemp "${runDir}/.fs-readonly.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT

    # PID 1's table, not ours: `ProtectSystem` sets every per-mount flag `ro`
    # in this unit's namespace, which would hide the fault signature.
    ${pkgs.gawk}/bin/awk -f ${./fs-forced-readonly.awk} /proc/1/mountinfo > "$tmp"

    # mktemp creates 0600; node_exporter (non-root) must read it.
    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "${runDir}/fs-readonly.prom"
  '';
in
{
  config = lib.mkIf isNode {

    # node_exporter merges per-mount and superblock `ro` (`isFilesystemReadOnly`):
    # it cannot tell an intended `ro` bind from a fault. Second textfile dir,
    # the flag is repeatable.
    services.prometheus.exporters.node.extraFlags = [ "--collector.textfile.directory=${runDir}" ];

    # At boot, before the first run: a missing dir is a textfile scrape error.
    systemd.tmpfiles.rules = [ "d ${runDir} 0755 root root -" ];

    systemd.services.dnf-fs-readonly = {
      description = "Export rw mounts the kernel turned read-only (node_exporter textfile)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = exportForcedReadonly;

        # `RuntimeDirectory`, not `ReadWritePaths`: created before the namespace,
        # so the first run after a switch cannot fail on a missing dir. Preserved,
        # or each oneshot exit would delete the exported file.
        RuntimeDirectory = baseNameOf runDir;
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
        ProtectSystem = "strict";
        PrivateNetwork = true;
        NoNewPrivileges = true;
      };
    };

    # Minutely: the rule's own `for: 5m` dominates the detection delay.
    systemd.timers.dnf-fs-readonly = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
