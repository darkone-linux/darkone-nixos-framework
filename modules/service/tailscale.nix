# Tailscale client of the DNF tailnet (headscale on the HCS).
#
# Joins the HCS, zone gateways (`isGateway`: zone subnet advertised, routes
# accepted, own resolver kept) and roaming hosts.
#
# :::note[Enrollment]
# No shared key. `just tailnet-enroll <host>`, also run by `just configure`,
# mints a single-use key tagged for the host on the HCS and hands it to
# `dnf-tailnet-join`. Idempotent: an enrolled node is left untouched.
# :::
#
# Sub-modules (`tailscale/`):
# - `cert-sync.nix`: zone gateways pull the HCS Caddy certificates;
# - `selfheal.nix`: watchdog restarting a disconnected tailscaled;
# - `autopause.nix`: roaming clients pause tailscale on a zone LAN.
#
# #### Certificate sync (`cert-sync.nix`)
#
# Public certificates are issued on the HCS only; each zone gateway pulls the
# whole Caddy storage over the tailnet (rsync as `nix`, elevated to `caddy` on
# the HCS side), then publishes it to its own Caddy.
#
# #### Self-heal (`selfheal.nix`)
#
# Every minute, checks that the backend runs and the control plane sees the
# node online; restarts tailscaled after a sustained loss. Exports
# `dnf_tailscale_*` metrics for the `TailscaleFlapping`/`TailscaleUnhealthy`
# alerts.
#
# #### Auto-pause (`autopause.nix`)
#
# Roaming clients only. On a DNF zone LAN, `--accept-dns` would hijack
# resolv.conf (local dnsmasq/AdGuard) and `--accept-routes` collide with the
# connected zone subnet: a NetworkManager dispatcher pauses tailscale there
# and resumes it elsewhere.

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

  # Control-plane bootstrap: on a gateway the headscale FQDN resolves through
  # the very VPN it establishes, and boot deadlocks (AdGuard waits on MagicDNS
  # before binding :53). Its public IP from config.yaml goes in /etc/hosts,
  # which tailscaled's Go resolver reads before any DNS.
  hcsHost = lib.findFirst (h: h.hostname == coord.hostname) null hosts;
  bootstrapHcs =
    hasHeadscale && !(dnfLib.isHcs host zone network) && hcsHost != null && (hcsHost.ip or "") != "";
  inherit (dnfLib.constants) caddyStorage;

  # Self-heal watchdog (`tailscale/selfheal.nix`).
  selfHealEnable = hasHeadscale && cfg.selfHeal.enable;
  selfHealStateDir = "/run/tailscale-selfheal";

  # Auto-pause state (`tailscale/autopause.nix`), also read by autoconnect and
  # by the self-heal watchdog, which stand down while paused.
  autoPauseEnable = cfg.autoPauseOnLan.enable;
  autoPauseStateDir = "/run/tailscale-autopause";
  autoPauseStateFile = "${autoPauseStateDir}/state";
  tsBin = "${config.services.tailscale.package}/bin/tailscale";

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

    # Values shared with the `tailscale/` sub-modules.
    darkone.service.tailscale.shared = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = {
        inherit
          tsBin
          isHcsSubnetGateway
          selfHealEnable
          selfHealStateDir
          autoPauseEnable
          autoPauseStateFile
          ;
      };
      defaultText = "computed";
      description = "Tailscale values shared with the `tailscale/` sub-modules.";
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

      # `server`: IP forwarding (exit node, subnet routes); `client`: loose
      # reverse path filtering; `both`: the two.
      useRoutingFeatures = if (cfg.isExitNode || cfg.isGateway) then "both" else "client";

      # Keeps the upstream autoconnect unit, whose script is replaced below;
      # filled by `dnf-tailnet-join` only.
      authKeyFile = enrollKeyFile;

      # Applied by `up` only; a running node reconciles `reconcileFlags`. Boolean
      # flags MUST read `--flag=value`: Go stops at `--accept-dns false`, and
      # `up` aborts with "too many non-flag arguments".
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

    # Upstream autoconnect (Type=notify, endless poll, `up` without timeout)
    # fails the unit, and the deploy, whenever Running is out of reach. Bounded
    # oneshot that never fails instead: the self-heal watchdog converges.
    # `services.tailscale.authKeyParameters` is not supported here.
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

    # Subnet gateway: tailnet trusted, loose reverse path, WireGuard on the WAN.
    networking.firewall = lib.mkIf isHcsSubnetGateway {
      trustedInterfaces = [ "tailscale0" ];
      checkReversePath = "loose"; # subnet routing
      interfaces.${wanInterface}.allowedUDPPorts = [ config.services.tailscale.port ];
    };

    #--------------------------------------------------------------------------
    # Packages and state dirs
    #--------------------------------------------------------------------------

    # Cert sync tooling (`tailscale/cert-sync.nix`), enrollment entry point.
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
  };
}
