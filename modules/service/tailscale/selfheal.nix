# DNF tailscale: self-heal watchdog.
#
# Every minute, checks that the backend runs and the control plane sees the
# node online; restarts tailscaled after a sustained loss. Exports
# `dnf_tailscale_*` metrics for the `TailscaleFlapping`/`TailscaleUnhealthy`
# alerts.

{
  lib,
  pkgs,
  config,
  dnfLib,
  ...
}:
let
  cfg = config.darkone.service.tailscale;
  inherit (cfg.shared)
    selfHealEnable
    selfHealStateDir
    autoPauseEnable
    autoPauseStateFile
    ;

  # Self-heal watchdog tunables. 3 failed ticks at 60s ≈ 3 min of sustained
  # disconnection before acting (rides out WAN blips); one restart per 10 min
  # max, so a deeper fault does not turn into a restart loop.
  selfHealFailThreshold = 3;
  selfHealCooldownSec = 600;

  # Metric write is best-effort: only supervised nodes have the collector dir.
  textfileDir = dnfLib.constants.textfileCollectorDir;
in
{
  config = lib.mkIf (cfg.enable && selfHealEnable) {

    # tailscaled can silently drop its headscale control connection, cutting a
    # gateway's subnet until a restart: detected locally, restarted.
    systemd.services.tailscale-selfheal = {
      description = "Restart tailscaled when it loses the headscale control connection";
      after = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "tailscale-selfheal" ''
          set -u
          ${lib.optionalString autoPauseEnable ''

            # Intentionally paused on a home LAN (autopause) → stand down, metric
            # included: a value frozen by the pause keeps TailscaleUnhealthy firing.
            if [ "$(${pkgs.coreutils}/bin/cat ${autoPauseStateFile} 2>/dev/null || echo away)" = "home" ]; then
              ${pkgs.coreutils}/bin/rm -f "${textfileDir}/tailscale.prom"
              exit 0
            fi
          ''}
          fails="${selfHealStateDir}/fails"
          last="${selfHealStateDir}/last-restart"
          restarts="${selfHealStateDir}/restarts"

          # Healthy iff the backend runs and control reports us online. Health
          # warnings are deliberately NOT a restart trigger: most are static
          # config notes (exit-node SNAT, SSH ACLs) a restart can never clear, so
          # gating on them pinned the node unhealthy and looped restarts forever.
          # The count is still exported (warn-only) for dashboard visibility.
          healthy=0
          warnings=0
          backend=unknown
          if status=$(${config.services.tailscale.package}/bin/tailscale status --json 2>/dev/null); then
            backend=$(echo "$status" | ${pkgs.jq}/bin/jq -r '.BackendState // "unknown"')
            warnings=$(echo "$status" | ${pkgs.jq}/bin/jq -r '.Health | length')
            online=$(echo "$status" | ${pkgs.jq}/bin/jq -r '.Self.Online // false')
            if [ "$backend" = "Running" ] && [ "$online" = "true" ]; then
              healthy=1
            fi
          fi

          if [ "$healthy" = "1" ]; then
            echo 0 > "$fails"

          # Not enrolled: a restart never brings a registration back, only
          # `just tailnet-enroll` does. TailscaleUnhealthy still reports it.
          elif [ "$backend" = "NeedsLogin" ]; then
            echo 0 > "$fails"
          else
            n=$(( $(${pkgs.coreutils}/bin/cat "$fails" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$fails"
            now=$(${pkgs.coreutils}/bin/date +%s)
            lastRestart=$(${pkgs.coreutils}/bin/cat "$last" 2>/dev/null || echo 0)

            # Act only on sustained loss, at most once per cooldown window.
            if [ "$n" -ge ${toString selfHealFailThreshold} ] && [ "$(( now - lastRestart ))" -ge ${toString selfHealCooldownSec} ]; then
              ${pkgs.util-linux}/bin/logger -t tailscale-selfheal "headscale disconnect ($n ticks), restarting tailscaled"
              ${pkgs.systemd}/bin/systemctl restart tailscaled.service tailscaled-autoconnect.service
              echo "$now" > "$last"
              echo 0 > "$fails"
              echo "$(( $(${pkgs.coreutils}/bin/cat "$restarts" 2>/dev/null || echo 0) + 1 ))" > "$restarts"
            fi
          fi

          # Best-effort node_exporter metric (only where the collector dir exists).
          if [ -d "${textfileDir}" ]; then
            count=$(${pkgs.coreutils}/bin/cat "$restarts" 2>/dev/null || echo 0)
            tmp=$(${pkgs.coreutils}/bin/mktemp "${textfileDir}/.tailscale.XXXXXX")
            {
              echo "dnf_tailscale_healthy $healthy"
              echo "dnf_tailscale_health_warnings $warnings"
              echo "dnf_tailscale_selfheal_restarts_total $count"
            } > "$tmp"

            # mktemp creates 0600; node_exporter runs as a non-root user and must
            # read it, so widen before the atomic rename.
            ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
            ${pkgs.coreutils}/bin/mv -f "$tmp" "${textfileDir}/tailscale.prom"
          fi
        '';
      };
    };

    systemd.timers.tailscale-selfheal = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "60s";
      };
    };
  };
}
