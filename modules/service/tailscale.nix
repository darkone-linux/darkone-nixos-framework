# Tailscale client service for HCS.
#
# :::note
# A tailscale client to connect an external host to HCS.
# Do not use it to connect a gateway for a tailnet subnet.
# :::

{
  lib,
  pkgs,
  config,
  zone,
  network,
  dnfLib,
  ...
}:
let
  cfg = config.darkone.service.tailscale;
  coord = network.coordination;
  wanInterface = zone.gateway.wan.interface;
  hasHeadscale = coord.enable;
  isHcsSubnetGateway = hasHeadscale && cfg.isGateway;
  hcsFqdn = "${coord.domain}.${network.domain}";
  hcsInternalFqdn = network.zones.${dnfLib.constants.globalZone}.gateway.vpn.ipv4;
  inherit (dnfLib.constants) caddyStorage;
  caddyStorTmp = "/tmp/caddy-storage-sync";

  # Self-heal watchdog tunables. 3 failed ticks at 60s ≈ 3 min of sustained
  # disconnection before acting (rides out WAN blips); one restart per 10 min
  # max, so a deeper fault does not turn into a restart loop.
  selfHealEnable = hasHeadscale && cfg.selfHeal.enable;
  selfHealFailThreshold = 3;
  selfHealCooldownSec = 600;
  selfHealStateDir = "/run/tailscale-selfheal";

  # node_exporter textfile collector dir (same value as monitoring.nix /
  # restic.nix). Metric write is best-effort: only supervised nodes have it.
  textfileDir = "/var/lib/node-exporter-textfile";
in
{
  options = {
    darkone.service.tailscale.enable = lib.mkEnableOption "Enable tailscale client to connect HCS";
    darkone.service.tailscale.isGateway = lib.mkEnableOption "This tailscale node is a subnet gateway";
    darkone.service.tailscale.isExitNode = lib.mkEnableOption "Configure this client as exit node";
    darkone.service.tailscale.selfHeal.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Watchdog: detect headscale disconnection and restart tailscaled.";
    };
  };

  config = lib.mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Security
    #--------------------------------------------------------------------------

    # Auth key hosted by sops
    sops.secrets = lib.mkIf hasHeadscale {
      "tailscale/authKey" = {
        mode = "0400";
        owner = "root";
        group = "root";
      };
    };

    #--------------------------------------------------------------------------
    # Tailscale client service
    #--------------------------------------------------------------------------

    services.tailscale = lib.mkIf hasHeadscale {
      enable = true;

      # To use in conjonction with tailscale up --advertise-exit-node
      # https://search.nixos.org/options?channel=unstable&show=services.tailscale.useRoutingFeatures&query=services.tailscale
      # server -> enable IP forwarding.
      # client -> reverse path filtering will be set to loose instead of strict.
      # both -> client + server
      useRoutingFeatures = if (cfg.isExitNode || cfg.isGateway) then "both" else "client";

      # Previously registered server key
      authKeyFile = config.sops.secrets."tailscale/authKey".path;

      # Register zone network addresses and connect to server
      # TODO: make these parameters set at tailscaled startup,
      #       for now must manually use "set" to apply settings.
      extraUpFlags = [
        "--login-server"
        "https://${hcsFqdn}"
        (lib.mkIf cfg.isExitNode "--advertise-exit-node")
        "--accept-routes"
        "--accept-dns"

        # NOTE: for now we can leave false but we no longer have MagicDNS, it is
        # dnsmasq that manages DNS behind AGH. But this is complicated and not very clean.
        # Solution to investigate: tailscale manages DNS with AGH as intermediary.
        (lib.mkIf cfg.isGateway "false")
        "--ssh" # Usefull to sync TLS certificates with HCS caddy.
        "--reset" # Reload.
      ]
      ++ lib.optionals cfg.isGateway [
        "--advertise-routes"
        "${zone.networkIp}/${toString zone.prefixLength}"
        "--snat-subnet-routes" # source NAT traffic to local routes advertised with --advertise-routes
        "false"
      ];
    };

    #--------------------------------------------------------------------------
    # Networking
    #--------------------------------------------------------------------------

    # Network permissions
    networking.firewall = lib.mkIf isHcsSubnetGateway {
      trustedInterfaces = [ "tailscale0" ];
      checkReversePath = "loose"; # subnet routing
      interfaces.${wanInterface}.allowedUDPPorts = [ config.services.tailscale.port ];
    };

    #--------------------------------------------------------------------------
    # Certificat sync
    #--------------------------------------------------------------------------
    # TODO: feedback on sync health status.

    # We need rsync
    environment.systemPackages = with pkgs; [
      rsync
      caddy
      openssl
    ];

    # Caddy storage dir (cert sync) + watchdog state dir, each behind its guard.
    systemd.tmpfiles.rules =
      lib.optionals isHcsSubnetGateway [ "d ${caddyStorage} 0750 caddy caddy -" ]
      ++ lib.optionals selfHealEnable [ "d ${selfHealStateDir} 0755 root root -" ];

    # TLS certificates (caddy storage) sync service
    systemd.services.sync-caddy-certs = lib.mkIf isHcsSubnetGateway {
      description = "Sync Caddy certificates from VPS via Tailscale";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "nix";
        ExecStart = pkgs.writeShellScript "sync-hcs-caddy-certs" ''

          # Sync from HCS with nix user
          /run/current-system/sw/bin/mkdir -p ${caddyStorTmp}
          /run/wrappers/bin/sudo ${pkgs.coreutils}/bin/chown -R nix ${caddyStorTmp}

          # Certificates extraction
          ${pkgs.rsync}/bin/rsync \
            -avz \
            --delete \
            --timeout=30 \
            -e "${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new" \
            --rsync-path="sudo -u caddy rsync" \
            nix@${hcsInternalFqdn}:${caddyStorage}/ \
            ${caddyStorTmp}/

          # Sync to caddy data dir with caddy user
          /run/wrappers/bin/sudo ${pkgs.coreutils}/bin/chown -R caddy:caddy ${caddyStorTmp}
            
          # Sync with local tailscale
          /run/wrappers/bin/sudo ${pkgs.rsync}/bin/rsync \
            -av \
            --delete \
            ${caddyStorTmp}/ \
            ${caddyStorage}/
        '';
      };
    };

    # TLS certificates (caddy storage) sync timer
    systemd.timers.sync-caddy-certs = lib.mkIf isHcsSubnetGateway {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
        Persistent = true;
      };
    };

    #--------------------------------------------------------------------------
    # Self-heal watchdog
    #--------------------------------------------------------------------------
    # Real incident: a gateway's tailscaled silently dropped its headscale
    # control connection, cutting subnet access until a manual restart. Detect
    # that state locally and restart tailscaled (its autoconnect oneshot re-runs
    # `tailscale up`, re-registering the node).

    systemd.services.tailscale-selfheal = lib.mkIf selfHealEnable {
      description = "Restart tailscaled when it loses the headscale control connection";
      after = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "tailscale-selfheal" ''
          set -u

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

    systemd.timers.tailscale-selfheal = lib.mkIf selfHealEnable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "60s";
      };
    };
  };
}
