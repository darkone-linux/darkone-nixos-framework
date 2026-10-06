# DNF tailscale: HCS certificate sync. Doc: `../tailscale.nix` header.

# TODO: feedback on sync health status.

{
  lib,
  pkgs,
  config,
  network,
  dnfLib,
  ...
}:
let
  cfg = config.darkone.service.tailscale;
  inherit (cfg.shared) tsBin isHcsSubnetGateway;
  inherit (dnfLib.constants) caddyStorage;
  hcsInternalFqdn = network.zones.${dnfLib.constants.globalZone}.gateway.vpn.ipv4;

  # Staging dir for the cert pull, provided as a systemd StateDirectory. NOT in
  # /tmp: a fixed path in a 1777 dir let a local user pre-create it as a symlink
  # and turn the unit's `chown -R` into an arbitrary root chown.
  caddyStorSyncName = "caddy-cert-sync";
  caddyStorTmp = "/var/lib/${caddyStorSyncName}";

  # Private key of the `nix` user, used for the pull. The unit runs as root, so
  # ssh cannot find it by itself (HOME=/root). Same path as admin/nix.nix.
  nixSshKey = "${config.users.users.nix.home}/.ssh/id_ed25519";

  # Cert-sync resilience tunables. A gateway cold-boot waits on its WAN uplink
  # (and on the ISP box behind it), then on tailscaled's exponential login
  # backoff: measured at ~2min40 on a real power-cut reboot, i.e. well past the
  # timer's 2min OnBootSec. The gate below absorbs that, the retries absorb the
  # blips that happen once the tailnet is up.
  tailnetWaitSec = 300;
  tailnetPollSec = 5;
  certSyncAttempts = 3;
  certSyncRetrySec = 20;

  # Gate on the tailnet being *usable*, not merely on tailscaled having
  # started: `after = tailscaled.service` only proves the daemon is up, and the
  # pull then fires into a dead control plane and leaves the oneshot `failed`
  # until the next tick. Same healthy predicate as the self-heal watchdog.
  waitForTailnet = pkgs.writeShellScript "wait-for-tailnet" ''
    set -u

    deadline=$(( $(${pkgs.coreutils}/bin/date +%s) + ${toString tailnetWaitSec} ))
    while : ;do
      if status=$(${tsBin} status --json 2>/dev/null); then
        backend=$(echo "$status" | ${pkgs.jq}/bin/jq -r '.BackendState // "unknown"')
        online=$(echo "$status" | ${pkgs.jq}/bin/jq -r '.Self.Online // false')
        if [ "$backend" = "Running" ] && [ "$online" = "true" ]; then
          exit 0
        fi
      fi

      # Bounded on purpose: a gateway with no tailnet after this long is a real
      # incident, and failing here is the only signal that says so.
      if [ "$(${pkgs.coreutils}/bin/date +%s)" -ge "$deadline" ]; then
        echo "wait-for-tailnet: still down after ${toString tailnetWaitSec}s" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep ${toString tailnetPollSec}
    done
  '';
in
{
  config = lib.mkIf (cfg.enable && isHcsSubnetGateway) {

    # TLS certificates (caddy storage) sync service
    systemd.services.sync-caddy-certs = {
      description = "Sync Caddy certificates from VPS via Tailscale";

      # `tailscaled-autoconnect` is the oneshot that runs `tailscale up`; the
      # ordering is best-effort (systemd ignores an absent unit) and is not
      # enough on its own, hence the ExecStartPre gate.
      after = [
        "network-online.target"
        "tailscaled.service"
        "tailscaled-autoconnect.service"
      ];
      wants = [
        "network-online.target"
        "tailscaled.service"
      ];
      serviceConfig = {
        Type = "oneshot";

        # The gate plus every retry must fit inside the start timeout, or
        # systemd kills the unit and marks it failed — the exact state the
        # retries exist to avoid.
        TimeoutStartSec = tailnetWaitSec + 600;
        ExecStartPre = waitForTailnet;

        # Root, not `nix`: sudo fails in a unit once ANSSI R39 sets
        # `requiretty` (no TTY).
        StateDirectory = caddyStorSyncName;
        StateDirectoryMode = "0700";
        ExecStart = pkgs.writeShellScript "sync-hcs-caddy-certs" ''

          # Without this, every step below can fail while the oneshot still
          # exits 0: certs stop syncing until they expire, with no alert.
          set -euo pipefail

          # Pull the HCS storage. The remote side still elevates to caddy: the
          # ACME files are 0600 caddy:caddy, unreadable by nix.
          #
          # Retried: the tailnet can be up yet the path to the HCS not settled
          # (DERP relay still negotiating), and a single blip used to leave the
          # unit failed for a full timer period. ConnectTimeout keeps a hung
          # handshake bounded, --timeout=30 covers the transfer itself.
          attempt=1
          while : ;do
            if ${pkgs.rsync}/bin/rsync \
              -avz \
              --delete \
              --timeout=30 \
              -e "${pkgs.openssh}/bin/ssh -i ${nixSshKey} -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
              --rsync-path="sudo -u caddy rsync" \
              nix@${hcsInternalFqdn}:${caddyStorage}/ \
              ${caddyStorTmp}/ ;then
              break
            fi
            if [ "$attempt" -ge ${toString certSyncAttempts} ]; then
              echo "sync-caddy-certs: pull failed after $attempt attempts" >&2
              exit 1
            fi
            attempt=$(( attempt + 1 ))
            ${pkgs.coreutils}/bin/sleep ${toString certSyncRetrySec}
          done

          # Never publish an empty staging dir: the --delete below would wipe
          # the live certificates and the ACME account key.
          if [ -z "$(${pkgs.findutils}/bin/find ${caddyStorTmp} -type f -print -quit)" ]; then
            echo "sync-caddy-certs: empty staging dir, refusing to publish" >&2
            exit 1
          fi

          # Publish to caddy's own storage.
          ${pkgs.rsync}/bin/rsync \
            -a \
            --delete \
            ${caddyStorTmp}/ \
            ${caddyStorage}/
          ${pkgs.coreutils}/bin/chown -R caddy:caddy ${caddyStorage}
        '';
      };
    };

    # TLS certificates (caddy storage) sync timer
    systemd.timers.sync-caddy-certs = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
        Persistent = true;
      };
    };
  };
}
