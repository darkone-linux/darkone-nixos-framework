# Tailscale client service for HCS.
#
# :::note
# A tailscale client to connect an external host to HCS.
# Do not use it to connect a gateway for a tailnet subnet.
# :::
#
# :::note[Enrollment]
# No shared key. `just tailnet-enroll <host>`, also run by `just configure`,
# mints a single-use key tagged for the host on the HCS and hands it to
# `dnf-tailnet-join`. Idempotent: an enrolled node is left untouched.
# :::

{
  lib,
  pkgs,
  config,
  zone,
  network,
  host,
  hosts,
  dnfLib,
  ...
}:
let
  cfg = config.darkone.service.tailscale;
  coord = network.coordination;
  wanInterface = zone.gateway.wan.interface;
  hasHeadscale = coord.enable;
  isHcsSubnetGateway = hasHeadscale && cfg.isGateway;

  # Zone subnet a gateway advertises to the tailnet (same value as the
  # --advertise-routes up flag below).
  gatewaySubnet = "${zone.networkIp}/${toString zone.prefixLength}";

  # Prefs `tailscale set` reconciles on an already Running node: set by hand or
  # by a bare first `up`, they survive restarts and never converge otherwise.
  reconcileFlags = [

    # Tailscale SSH shadows sshd on the tailnet IP, then denies: no `ssh` policy.
    "--ssh=false"
    "--advertise-exit-node=${lib.boolToString cfg.isExitNode}"
  ]

  # Without them a gateway's zone is unreachable from the tailnet, and replies
  # to other zones leak out the WAN (no return route).
  ++ lib.optionals cfg.isGateway [
    "--accept-routes"
    "--advertise-routes=${gatewaySubnet}"
    "--snat-subnet-routes=false"
  ];
  hcsFqdn = "${coord.domain}.${network.domain}";
  hcsInternalFqdn = network.zones.${dnfLib.constants.globalZone}.gateway.vpn.ipv4;

  # Control-plane bootstrap. Gateways route the whole network domain to the
  # tailnet DNS server, so the headscale FQDN resolves *through the VPN it is
  # used to establish*; today it only works because the resolver falls back to
  # public upstreams once the split-DNS server times out. Worse on a gateway
  # boot: tailscaled waits on a resolver that is itself waiting on the tailnet
  # (AdGuard reverse-resolves its tailnet address through MagicDNS before
  # binding :53). Pinning the public IP — declared in config.yaml, same source
  # as everything else — cuts the loop: tailscaled is statically linked against
  # Go's own resolver, which reads the hosts file before any DNS, so the
  # control plane stays reachable even with the local resolver down.
  hcsHost = lib.findFirst (h: h.hostname == coord.hostname) null hosts;
  bootstrapHcs =
    hasHeadscale && !(dnfLib.isHcs host zone network) && hcsHost != null && (hcsHost.ip or "") != "";
  inherit (dnfLib.constants) caddyStorage;

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

  # Auto-pause (roaming client). On a home zone LAN, --accept-dns hijacks
  # resolv.conf (kills local dnsmasq/AGH) and --accept-routes collides with the
  # directly-connected zone subnet. A NM dispatcher pauses tailscale there and
  # resumes it elsewhere; a shared state file lets the self-heal watchdog stand
  # down while paused.
  autoPauseEnable = cfg.autoPauseOnLan.enable;
  autoPauseStateDir = "/run/tailscale-autopause";
  autoPauseStateFile = "${autoPauseStateDir}/state";
  tsBin = "${config.services.tailscale.package}/bin/tailscale";

  # DNF zones are all /16; match on the two-octet ipPrefix. The external
  # global/HCS zone has no LAN prefix, so it is filtered out.
  zoneLanPrefixes = lib.pipe network.zones [
    (lib.filterAttrs (name: _: name != dnfLib.constants.globalZone))
    (lib.mapAttrsToList (_: z: z.ipPrefix))
  ];

  # Shared decision, invoked from both the NM dispatcher (roaming) and a boot
  # oneshot (already in a zone at startup). Idempotent against the *real* backend
  # state rather than a stored transition, so it is safe on every event and
  # closes the boot race where tailscaled-autoconnect brings the VPN up before
  # any dispatcher event fires.
  autoPauseScript = pkgs.writeShellScript "tailscale-autopause" ''
    set -u

    state="${autoPauseStateFile}"
    ts="${config.services.tailscale.package}/bin/tailscale"

    # IPv4s currently held on physical interfaces (exclude tailscale0 + lo).
    addrs=$(${pkgs.iproute2}/bin/ip -o -4 addr show 2>/dev/null \
      | ${pkgs.gawk}/bin/awk '$2 != "lo" && $2 != "tailscale0" { print $4 }')

    # Home iff one of them sits in a known DNF zone /16 (two-octet prefix).
    desired=away
    for prefix in ${lib.concatStringsSep " " zoneLanPrefixes}; do
      if echo "$addrs" | ${pkgs.gnugrep}/bin/grep -q "^$prefix\."; then
        desired=home
        break
      fi
    done

    # Record intent first so the self-heal watchdog stands down without racing.
    echo "$desired" > "$state"

    # unknown while tailscaled is not up yet (early boot): the boot oneshot,
    # ordered after autoconnect, re-runs and enforces once the backend exists.
    backend=unknown
    if s=$($ts status --json 2>/dev/null); then
      backend=$(echo "$s" | ${pkgs.jq}/bin/jq -r '.BackendState // "unknown"')
    fi

    if [ "$desired" = home ]; then
      if [ "$backend" != Stopped ] && [ "$backend" != unknown ]; then
        ${pkgs.util-linux}/bin/logger -t tailscale-autopause "on DNF zone LAN, pausing tailscale"
        $ts down
      fi
    else
      if [ "$backend" = Stopped ]; then
        ${pkgs.util-linux}/bin/logger -t tailscale-autopause "off DNF zone LAN, resuming tailscale"

        # Re-run autoconnect to reapply the exact configured flags (+ --reset).
        ${pkgs.systemd}/bin/systemctl restart tailscaled-autoconnect.service
      fi
    fi
  '';

  # Single-use key dropped by `dnf-tailnet-join`, consumed by autoconnect. tmpfs:
  # never on persistent storage, gone at reboot.
  enrollDir = "/run/tailscale-enroll";
  enrollKeyFile = "${enrollDir}/authKey";

  # Enrollment while autopaused on a home LAN: registers without the routes and
  # DNS autopause avoids there; the next resume re-applies extraUpFlags.
  enrollHomeFlags = [
    "--login-server"
    "https://${hcsFqdn}"
    "--accept-routes=false"
    "--accept-dns=false"
    "--reset"
  ];

  # Root side of `just tailnet-enroll`: key on stdin, handed to autoconnect.
  # Prints the resulting backend state and node key, never the key itself.
  joinCmd = "dnf-tailnet-join";
  joinBin = "/run/current-system/sw/bin/${joinCmd}";
  joinScript = pkgs.writeShellScriptBin joinCmd ''
    set -euo pipefail
    umask 077

    key=$(${pkgs.coreutils}/bin/head -c 1024 | ${pkgs.coreutils}/bin/tr -d '[:space:]')
    if [ -z "$key" ]; then
      echo "${joinCmd}: no key on stdin" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/install -d -m 0700 ${enrollDir}
    trap '${pkgs.coreutils}/bin/rm -f ${enrollKeyFile}' EXIT
    printf '%s' "$key" > ${enrollKeyFile}

    # Runs in systemd, not in this session: survives a tailnet SSH drop.
    ${pkgs.systemd}/bin/systemctl restart tailscaled-autoconnect.service
    ${tsBin} status --json --peers=false \
      | ${pkgs.jq}/bin/jq -c '{state: .BackendState, nodeKey: (.Self.PublicKey // null)}'
  '';
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
    darkone.service.tailscale.autoPauseOnLan.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Roaming client: pause tailscale (down) while plugged into a known DNF
        zone LAN, resume it elsewhere. Non-gateway NetworkManager clients only.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Enrollment
    #--------------------------------------------------------------------------

    # `dnf-tailnet-join` for the deploy user. NOLOG_*: the key crosses sudo,
    # kept out of the R39 I/O logs.
    security.sudo.extraRules = lib.mkIf hasHeadscale [
      {
        users = [ "nix" ];
        runAs = "root";
        commands = [
          {
            command = joinBin;
            options = [
              "NOPASSWD"
              "NOLOG_INPUT"
              "NOLOG_OUTPUT"
            ];
          }
        ];
      }
    ];
    darkone.security.sudo.allowedRootRules = lib.mkIf hasHeadscale [ joinBin ];

    #--------------------------------------------------------------------------
    # Control plane bootstrap
    #--------------------------------------------------------------------------

    # Static because it must answer before the resolver exists (cf. hcsHost
    # above). /etc/hosts wins over DNS, so a moved VPS needs a redeploy of the
    # tailscale clients — the same contract as every other value derived from
    # config.yaml.
    networking.hosts = lib.mkIf bootstrapHcs { ${hcsHost.ip} = [ hcsFqdn ]; };

    #--------------------------------------------------------------------------
    # Tailscale client service
    #--------------------------------------------------------------------------

    services.tailscale = lib.mkIf hasHeadscale {
      enable = true;

      # HCS: public VPS, one interface, so the global upstream rule is its WAN
      # rule. Peers behind a strict NAT reach it without hole punching.
      openFirewall = dnfLib.isHcs host zone network;

      # To use in conjonction with tailscale up --advertise-exit-node
      # https://search.nixos.org/options?channel=unstable&show=services.tailscale.useRoutingFeatures&query=services.tailscale
      # server -> enable IP forwarding.
      # client -> reverse path filtering will be set to loose instead of strict.
      # both -> client + server
      useRoutingFeatures = if (cfg.isExitNode || cfg.isGateway) then "both" else "client";

      # Keeps the upstream autoconnect unit, whose script is replaced below;
      # filled by `dnf-tailnet-join` only.
      authKeyFile = enrollKeyFile;

      # Register zone network addresses and connect to server
      # TODO: make these parameters set at tailscaled startup,
      #       for now must manually use "set" to apply settings.
      # Boolean flags MUST be written `--flag=value`: Go's flag parser treats a
      # space-separated `--accept-dns false` as flag + positional, stops parsing
      # there and aborts with "too many non-flag arguments" — the whole `up`
      # fails and the node never registers.
      extraUpFlags = [
        "--login-server"
        "https://${hcsFqdn}"
        (lib.mkIf cfg.isExitNode "--advertise-exit-node")
        "--accept-routes"

        # Gateways keep their own resolver (AdGuard Home → dnsmasq), which their
        # zone depends on. Clients take MagicDNS: node names, split DNS to the HCS.
        (if cfg.isGateway then "--accept-dns=false" else "--accept-dns")
        "--reset" # Reload.
      ]
      ++ lib.optionals cfg.isGateway [
        "--advertise-routes=${gatewaySubnet}"

        # Source NAT traffic to local routes advertised with --advertise-routes.
        "--snat-subnet-routes=false"
      ];
    };

    # Upstream autoconnect is fragile: Type=notify, endless poll loop, `up`
    # without --timeout. Whenever the backend cannot reach Running within the
    # 90s unit timeout (headscale unreachable, backend pinned in NoState,
    # autopause `down`), the unit fails → monitoring alert + deploy abort.
    # Replaced by a bounded oneshot that never fails: reaching Running is the
    # self-heal watchdog's job, not the boot/deploy critical path.
    # NOTE: services.tailscale.authKeyParameters is not supported here.
    systemd.services.tailscaled-autoconnect = lib.mkIf hasHeadscale {
      serviceConfig = {
        Type = lib.mkForce "oneshot";

        # Active once run: a switch restarts it when its script changes, so a
        # deploy reconciles prefs instead of waiting for the next boot.
        RemainAfterExit = true;

        # Script self-bounds at ~90s (30s backend wait + 60s up); safety net.
        TimeoutStartSec = 120;
      };
      script = lib.mkForce ''
        getState() {
          ${tsBin} status --json --peers=false 2>/dev/null \
            | ${pkgs.jq}/bin/jq -r '.BackendState // "unknown"' 2>/dev/null || echo unknown
        }

        # Let tailscaled leave its transient startup states; upstream waited
        # on these passively until the unit timeout (NoState incident, gw-ag).
        state=$(getState)
        tries=0
        while [ "$tries" -lt 30 ]; do
          case "$state" in
            NoState|Starting|unknown|"") ;;
            *) break ;;
          esac
          ${pkgs.coreutils}/bin/sleep 1
          tries=$((tries + 1))
          state=$(getState)
        done
        ${lib.optionalString autoPauseEnable ''

          # Autopaused on a home zone LAN: up with routes and DNS would hijack
          # the zone LAN and local DNS, and fight the NM dispatcher.
          home=0
          if [ "$(${pkgs.coreutils}/bin/cat ${autoPauseStateFile} 2>/dev/null || echo away)" = home ]; then
            home=1
          fi
        ''}

        # Key dropped by `dnf-tailnet-join`: register whatever the state, over a
        # stale registration too (--force-reauth), then drop the key.
        if [ -s ${enrollKeyFile} ]; then
          set -- ${lib.escapeShellArgs config.services.tailscale.extraUpFlags}
          ${lib.optionalString autoPauseEnable ''
            if [ "$home" = 1 ]; then
              set -- ${lib.escapeShellArgs enrollHomeFlags}
            fi
          ''}
          echo "enrollment key found (backend: $state), registering"
          if ${tsBin} up --auth-key "file:${enrollKeyFile}" --force-reauth --timeout 60s "$@"; then
            echo "tailscale registered"
          else
            echo "registration failed" >&2
          fi
          ${pkgs.coreutils}/bin/rm -f ${enrollKeyFile}
          ${lib.optionalString autoPauseEnable ''
            if [ "$home" = 1 ]; then
              ${tsBin} down || true
            fi
          ''}
          exit 0
        fi
        ${lib.optionalString autoPauseEnable ''
          if [ "$home" = 1 ]; then
            echo "autopause: on a home zone LAN, not connecting"
            exit 0
          fi
        ''}
        case "$state" in
          Running)
            echo "tailscale already running"

            # Idempotent, touches only these flags; the `up` branch never re-runs.
            ${tsBin} set ${lib.escapeShellArgs reconcileFlags} \
              || echo "prefs reconcile failed, deferring to self-heal" >&2
            exit 0
            ;;
          Stopped)
            echo "backend is Stopped, bringing it up"

            # --timeout replaces the forever-blocking `up` that got SIGTERMed on fl-01.
            if ${tsBin} up --timeout 45s \
              ${lib.escapeShellArgs config.services.tailscale.extraUpFlags}; then
              echo "tailscale is running"
              exit 0
            fi
            ;;
          NeedsLogin|NeedsMachineAuth)

            # No shared key: only an explicit enrollment registers a node.
            echo "not enrolled: run 'just tailnet-enroll ${host.hostname}' from the admin host" >&2
            exit 0
            ;;
        esac

        # Warn, do not fail: boots and deploys must not hinge on headscale
        # reachability; the self-heal watchdog converges within minutes.
        echo "backend not Running (state: $state), deferring to self-heal" >&2
      '';
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

    # Roaming transitions: NM dispatcher re-evaluates on every network event.
    networking.networkmanager.dispatcherScripts = lib.mkIf autoPauseEnable [
      {
        source = autoPauseScript;
        type = "basic";
      }
    ];

    # Boot in a zone: enforce once tailscaled-autoconnect ran and the LAN has an
    # IP, otherwise the autoconnect `up` leaves the VPN active on the home LAN.
    systemd.services.tailscale-autopause = lib.mkIf autoPauseEnable {
      description = "Pause tailscale at boot while on a home zone LAN";
      after = [
        "tailscaled-autoconnect.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = autoPauseScript;
      };
    };

    # Dispatcher-based; NetworkManager must own the interfaces.
    assertions = lib.optionals autoPauseEnable [
      {
        assertion = config.networking.networkmanager.enable;
        message = "darkone.service.tailscale.autoPauseOnLan requires networking.networkmanager.enable.";
      }
    ];

    #--------------------------------------------------------------------------
    # Certificat sync
    #--------------------------------------------------------------------------
    # TODO: feedback on sync health status.

    # We need rsync; `dnf-tailnet-join` is the enrollment entry point (above).
    environment.systemPackages = [
      pkgs.rsync
      pkgs.caddy
      pkgs.openssl
    ]
    ++ lib.optional hasHeadscale joinScript;

    # Caddy storage dir (cert sync) + watchdog state dir, each behind its guard.
    systemd.tmpfiles.rules =
      lib.optionals isHcsSubnetGateway [ "d ${caddyStorage} 0750 caddy caddy -" ]
      ++ lib.optionals selfHealEnable [ "d ${selfHealStateDir} 0755 root root -" ]
      ++ lib.optionals autoPauseEnable [ "d ${autoPauseStateDir} 0755 root root -" ];

    # TLS certificates (caddy storage) sync service
    systemd.services.sync-caddy-certs = lib.mkIf isHcsSubnetGateway {
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

        # Runs as root, on purpose: the former `User = "nix"` needed four sudo
        # calls, and sudo is unusable from a unit as soon as ANSSI R39 sets
        # `requiretty` (no TTY) — they failed silently on every hardened host.
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
    # and reconnects the node).

    systemd.services.tailscale-selfheal = lib.mkIf selfHealEnable {
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

    systemd.timers.tailscale-selfheal = lib.mkIf selfHealEnable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "60s";
      };
    };
  };
}
