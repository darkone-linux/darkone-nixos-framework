# The main gateway / router of a local network zone.
#
# :::tip[A ready-to-use gateway!]
# The gateway is configured in `usr/config.yaml` file.
# Additional enabled services (homepage, adguardhome, forgejo, nix-cache...)
# are automatically configured with consistent network plumbing on the
# gateway and all machines on the local network.
# :::
#
# :::caution[Routed traffic is filtered]
# `filterForward = true`: only LAN <-> WAN and LAN <-> tailnet cross. Anything
# else is dropped — add it to `networking.firewall.extraForwardRules`.
# :::
#
# :::tip[Backup links: Internet in degraded mode]
# `backupLinks` adds uplinks (spare ethernet port, wifi client such as a phone
# hotspot) the zone falls back to when the WAN loses its link, its lease or
# the Internet:
#
# ```nix
# darkone.host.gateway.backupLinks.phone = {
#   type = "wifi";          # SSID + passphrase: sops `backup-link/phone/{ssid,psk}`
#   interface = "wlp4s0";
#   priority = 10;          # lower = preferred among backups
# };
# ```
#
# Route metrics steer the default route; `dnf-uplink-monitor` pings through
# each link, penalises one without Internet and keeps one back from an outage
# on probation until it answers. A wifi backup keeps its radio
# off until no preferred link reaches the Internet; an ethernet one stays up,
# idle. Details: `lib/uplinks.nix`.
# :::

{
  lib,
  config,
  pkgs,
  dnfConfig,
  dnfLib,
  network,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.host.gateway;
  hasHeadscale = network.coordination.enable;
  hasAdguardHome = config.darkone.service.adguardhome.enable;

  # Never re-type an interface name: a hand-written one stops matching silently.
  inherit (dnfLib.constants) lanInterface vpnInterface internetProbeTargets;

  #----------------------------------------------------------------------------
  # Backup links (lazy: zone.gateway.wan only exists on a zone gateway)
  #----------------------------------------------------------------------------

  hasBackupLinks = cfg.backupLinks != { };
  wanInterface = zone.gateway.wan.interface;
  uplinks = dnfLib.mkUplinks {
    inherit wanInterface;
    inherit (cfg) backupLinks;
  };
  backupUplinks = lib.filter (u: u.role == "backup") uplinks;
  backupInterfaces = map (u: u.interface) backupUplinks;
  wifiInterfaces = map (u: u.interface) (lib.filter (u: u.type == "wifi") backupUplinks);
  wifiLinkNames = lib.attrNames (lib.filterAttrs (_: l: l.type == "wifi") cfg.backupLinks);
  hasWifiLinks = wifiLinkNames != [ ];
  wpaTemplate = "wpa-backup-links.conf";

  # nft anonymous set of interface names: `{ "a", "b" }`.
  nftIfaceSet = ifaces: "{ ${lib.concatMapStringsSep ", " (i: ''"${i}"'') ifaces} }";

  # Interfaces a backup link must not claim, with their role for the message.
  hostapdRadios = lib.optionals config.services.hostapd.enable (
    lib.attrNames config.services.hostapd.radios
  );
  reservedInterfaces =
    lib.genAttrs zone.gateway.lan.interfaces (_: "zone LAN port")
    // lib.genAttrs hostapdRadios (_: "hostapd radio")
    // {
      ${lanInterface} = "zone LAN bridge";
      ${vpnInterface} = "tailnet interface";
    };

  uplinkConflicts = dnfLib.uplinkConflicts {
    inherit wanInterface reservedInterfaces;
    inherit (cfg) backupLinks;
  };

  # Same collector dir as `service/monitoring.nix`; written only if present.
  textfileDir = "/var/lib/node-exporter-textfile";

  coreutils = "${pkgs.coreutils}/bin";
  ip = "${pkgs.iproute2}/bin/ip";
  rfkill = "${pkgs.util-linux}/bin/rfkill";
  bashArray = xs: lib.concatMapStringsSep " " lib.escapeShellArg xs;
  check = cfg.linkCheck;

  # Health probe + failover. Parallel arrays, one slot per uplink, primary
  # first. `pen`: 0, `probation` (lost, unproven since) or `penalty` (no
  # Internet); cleared after `recoverAfter` good rounds. Standby radios
  # follow the same hysteresis.
  monitorScript = pkgs.writeShellScript "dnf-uplink-monitor" ''
    set -u

    ifaces=(${bashArray (map (u: u.interface) uplinks)})
    files=(${bashArray (map (u: u.networkFile) uplinks)})
    metrics=(${bashArray (map (u: toString u.metric) uplinks)})
    roles=(${bashArray (map (u: u.role) uplinks)})
    standby=(${bashArray (map (u: if u.standby then "1" else "0") uplinks)})
    targets=(${bashArray check.targets})
    penalty=${toString dnfLib.uplinkPenalty}
    probation=${toString dnfLib.uplinkProbation}
    runtime=/run/systemd/network
    dropin=90-dnf-penalty.conf
    textfile=${textfileDir}

    # Bound to the interface (SO_BINDTODEVICE): follows that link's own
    # default route, even when another link is preferred.
    reachable() {
      local t
      for t in "''${targets[@]}"; do
        ${pkgs.iputils}/bin/ping -n -q -c 1 -W 2 -I "$1" "$t" >/dev/null 2>&1 && return 0
      done
      return 1
    }

    # Runtime drop-in over the link's own networkd file; `reload`
    # reconfigures that link only: fresh lease, new route metric.
    set_penalty() {
      local dir="$runtime/''${files[$1]}.network.d"
      if (( $2 )); then
        ${coreutils}/mkdir -p "$dir"
        printf '[DHCPv4]\nRouteMetric=%s\n' "$(( metrics[$1] + $2 ))" >"$dir/.$dropin.tmp"
        ${coreutils}/mv -f "$dir/.$dropin.tmp" "$dir/$dropin"
      else
        ${coreutils}/rm -f "$dir/$dropin"
      fi
      pen[$1]=$2
      ${pkgs.systemd}/bin/networkctl reload
    }

    # Penalty held by a drop-in of a previous run; unknown value: `penalty`.
    read_penalty() {
      local k v p=0
      [ -e "$1" ] || { echo 0; return; }
      while IFS='=' read -r k v; do
        [ "$k" = RouteMetric ] && p=$(( v - metrics[$2] ))
      done <"$1"
      (( p == probation )) || p=$penalty
      echo "$p"
    }

    # rfkill node of the phy behind a radio; looked up on each call, a
    # firmware reprobe brings a new phy.
    rfkill_dir() {
      local d
      for d in /sys/class/net/"$1"/phy80211/rfkill*; do
        [ -e "$d/soft" ] && echo "$d" && return 0
      done
      return 1
    }

    # Idempotent: also turns off a radio switched on behind our back
    # (systemd-rfkill restore, driver reprobe).
    sync_radio() {
      local d want
      d=$(rfkill_dir "''${ifaces[$1]}") || return 0
      want=$(( !engaged[$1] ))
      [ "$(<"$d/soft")" = "$want" ] && return 0
      if (( want )); then
        echo "''${ifaces[$1]} (''${roles[$1]}): radio off, a preferred link is healthy"
        ${rfkill} block "$(<"$d/index")"
      else
        echo "''${ifaces[$1]} (''${roles[$1]}): radio on, no preferred link reaches the Internet"
        ${rfkill} unblock "$(<"$d/index")"
      fi
    }

    # "dev src" of the preferred live default route (main table).
    active() {
      ${ip} -4 route show default | ${pkgs.gawk}/bin/awk '
        /linkdown/ { next }
        {
          m = 0; d = ""; s = ""
          for (i = 1; i < NF; i++) {
            if ($i == "metric") m = $(i + 1)
            if ($i == "dev") d = $(i + 1)
            if ($i == "src") s = $(i + 1)
          }
          if (d != "" && (bd == "" || m + 0 < bm + 0)) { bm = m; bd = d; bs = s }
        }
        END { if (bd != "") print bd, bs }'
    }

    write_metrics() {
      [ -d "$textfile" ] || return 0
      local tmp i up act
      tmp=$(${coreutils}/mktemp "$textfile/.dnf-uplinks.XXXXXX") || return 0
      {
        echo "# HELP dnf_gateway_link_up 1 when the uplink has a route and reaches the Internet."
        echo "# TYPE dnf_gateway_link_up gauge"
        for i in "''${!ifaces[@]}"; do
          up=$(( absent[i] == 0 && pen[i] == 0 ))
          echo "dnf_gateway_link_up{interface=\"''${ifaces[i]}\",role=\"''${roles[i]}\"} $up"
        done
        echo "# HELP dnf_gateway_link_active 1 on the uplink carrying the default route."
        echo "# TYPE dnf_gateway_link_active gauge"
        for i in "''${!ifaces[@]}"; do
          act=0
          [ "''${ifaces[i]}" = "$dev" ] && act=1
          echo "dnf_gateway_link_active{interface=\"''${ifaces[i]}\",role=\"''${roles[i]}\"} $act"
        done
        echo "# HELP dnf_gateway_link_standby 1 when the uplink radio is held off, a preferred link being healthy."
        echo "# TYPE dnf_gateway_link_standby gauge"
        for i in "''${!ifaces[@]}"; do
          echo "dnf_gateway_link_standby{interface=\"''${ifaces[i]}\",role=\"''${roles[i]}\"} $(( standby[i] && !engaged[i] ))"
        done
      } >"$tmp"

      # node_exporter is not root: widen mktemp's 0600 before the rename.
      ${coreutils}/chmod 0644 "$tmp"
      ${coreutils}/mv -f "$tmp" "$textfile/dnf-uplinks.prom"
    }

    # Restart-safe: a drop-in left by a previous run is the current state,
    # and so is a standby radio found on (failover in progress).
    declare -a fails oks absent pen engaged
    for i in "''${!ifaces[@]}"; do
      fails[i]=0 oks[i]=0 absent[i]=0 engaged[i]=0
      pen[i]=$(read_penalty "$runtime/''${files[i]}.network.d/$dropin" "$i")
      if (( standby[i] )) && d=$(rfkill_dir "''${ifaces[i]}"); then
        [ "$(<"$d/soft")" = 0 ] && engaged[i]=1
      fi
    done

    read -r dev src <<<"$(active)"
    prev_dev=$dev prev_src=$src

    while true; do
      for i in "''${!ifaces[@]}"; do
        iface=''${ifaces[i]}

        # No route for `failAfter` rounds: the link comes back on probation,
        # behind healthy links, ahead of dead ones (box rebooting, hotspot
        # switched on). Fewer rounds: lease gap of our own `networkctl reload`.
        if [ -z "$(${ip} -4 route show default dev "$iface" 2>/dev/null)" ]; then
          fails[i]=0 oks[i]=0
          (( absent[i] < ${toString check.failAfter} )) && absent[i]=$(( absent[i] + 1 ))
          if (( pen[i] != probation && absent[i] >= ${toString check.failAfter} )); then
            echo "$iface (''${roles[i]}): no route, on probation when back"
            set_penalty "$i" "$probation"
          fi
          continue
        fi
        absent[i]=0

        if reachable "$iface"; then
          fails[i]=0
          (( oks[i] < ${toString check.recoverAfter} )) && oks[i]=$(( oks[i] + 1 ))
          if (( pen[i] && oks[i] >= ${toString check.recoverAfter} )); then
            echo "$iface (''${roles[i]}): Internet back, route metric ''${metrics[i]}"
            set_penalty "$i" 0
          fi
        else
          oks[i]=0
          (( fails[i] < ${toString check.failAfter} )) && fails[i]=$(( fails[i] + 1 ))
          if (( pen[i] != penalty && fails[i] >= ${toString check.failAfter} )); then
            echo "$iface (''${roles[i]}): no Internet, route metric $(( metrics[i] + penalty ))"
            set_penalty "$i" "$penalty"
          fi
        fi
      done

      # Standby radio: on once every preferred link is lost (no Internet, or
      # no route for `failAfter` rounds), off once one is healthy again.
      # Links are ordered by metric: preferred ones come first.
      for i in "''${!ifaces[@]}"; do
        (( standby[i] )) || continue
        lost=1 held=0
        for (( j = 0; j < i; j++ )); do
          (( pen[j] != penalty && absent[j] < ${toString check.failAfter} )) && lost=0
          (( !pen[j] && !absent[j] && oks[j] >= ${toString check.recoverAfter} )) && held=1
        done
        if (( engaged[i] && held )); then
          engaged[i]=0
        elif (( !engaged[i] && lost )); then
          engaged[i]=1
        fi
        sync_radio "$i"
      done

      # Masqueraded flows keep the address of the link they started on: drop
      # them when the preferred link changes, their next packet is NATed anew.
      read -r dev src <<<"$(active)"
      if [ "$dev" != "$prev_dev" ]; then
        echo "default route: ''${prev_dev:-none} -> ''${dev:-none}"
        if [ -n "$prev_src" ]; then
          echo "conntrack: $(${pkgs.conntrack-tools}/bin/conntrack -D --src-nat --reply-dst "$prev_src" 2>&1 >/dev/null)"
        fi
      fi
      prev_dev=$dev prev_src=$src

      write_metrics
      ${coreutils}/sleep ${toString check.interval}
    done
  '';

  # Ports opened with no iifname, flattened for the assertion below.
  fw = config.networking.firewall;
  globalPorts =
    map (p: "tcp/${toString p}") fw.allowedTCPPorts
    ++ map (r: "tcp/${toString r.from}-${toString r.to}") fw.allowedTCPPortRanges
    ++ map (p: "udp/${toString p}") fw.allowedUDPPorts
    ++ map (r: "udp/${toString r.from}-${toString r.to}") fw.allowedUDPPortRanges;
  profileServicesArgs = {
    profileName = "gateway";
    inherit host;
    inherit (dnfConfig) modules;
  };
in
{
  options = {
    darkone.host.gateway.enable = lib.mkEnableOption "Enable gateway features for the current host (dhcp, dns, proxy, etc.)";

    darkone.host.gateway.backupLinks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            type = lib.mkOption {
              type = lib.types.enum [
                "ethernet"
                "wifi"
              ];
              description = ''
                `ethernet`: DHCP client on a spare port, always up. `wifi`:
                WPA2/WPA3 client, radio off (rfkill) until no preferred link
                reaches the Internet; SSID and passphrase are read from sops
                (`backup-link/<name>/ssid`, `backup-link/<name>/psk`).
              '';
            };
            interface = lib.mkOption {
              type = lib.types.str;
              example = "wlp4s0";
              description = "Interface carrying the link: neither the WAN, a LAN port nor a hostapd radio.";
            };
            priority = lib.mkOption {
              type = lib.types.ints.between 1 99;
              default = 10;
              description = ''
                Lower is preferred among backup links (route metric
                200 + 10 × priority, the WAN staying at 100).
              '';
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          phone = { type = "wifi"; interface = "wlp4s0"; };
          neighbour = { type = "ethernet"; interface = "eno3"; priority = 20; };
        }
      '';
      description = ''
        Fallback uplinks, used when the WAN has no link, no lease or no
        Internet. Name: `[a-z][a-z0-9-]*`.
      '';
    };

    darkone.host.gateway.linkCheck = {
      targets = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        default = internetProbeTargets;
        description = "IP addresses pinged through each uplink; one answer is enough. IP literals only: the probe must not depend on DNS.";
      };
      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Seconds between two probe rounds.";
      };
      failAfter = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Failed rounds before an uplink is penalised.";
      };
      recoverAfter = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6;
        description = "Good rounds before a penalised uplink is restored (hysteresis).";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        darkone.host.server.enable = true;

        # Gateways usually live on small root partitions and rebuild often:
        # keep only the last system generations instead of 30 days of history.
        darkone.system.core.gcKeepGenerations = lib.mkDefault 5;

        # Headless: a Nerd font on the TTY buys nothing, and kmscon is a known
        # CPU hog when its console goes stale. Plain getty is enough.
        darkone.system.core.enableKmscon = lib.mkDefault false;

        # Tailscale as a VPN gateway when headscale coordination is active.
        # Subnet router only: exit-node stays opt-in per host. Advertising it
        # here conflicted with `--snat-subnet-routes=false` (needed for clean
        # subnet source IPs) and only produced a permanent health warning.
        darkone.service.tailscale = lib.mkIf hasHeadscale {
          enable = true;
          isGateway = true;
        };

        #--------------------------------------------------------------------------
        # Routed traffic (forward chain)
        #--------------------------------------------------------------------------

        # Routed packets bypass the input chain, and without `filterForward`
        # there is no forward chain at all: kernel policy ACCEPT, i.e. an open
        # route Internet -> zone subnet on a gateway with a public WAN.
        #
        # `established,related` and `ct status dnat` (port forwards) come from
        # the upstream chains. `iifname` matches a string, so a rule may name
        # an interface that does not exist yet.
        networking.firewall = {

          # mkDefault: an unusual gateway (container runtime, second uplink)
          # opts out in its host file, and owns the consequence.
          filterForward = lib.mkDefault true;

          # LAN -> WAN is absent on purpose: the nat module appends its own
          # rules to this chain, from the internalInterfaces / internalIPs set
          # in `service/dnsmasq.nix`.
          extraForwardRules = ''
            # Subnet routing. `--snat-subnet-routes=false` keeps the tailnet
            # source IP, so without these an advertised route is unusable.
            iifname "${vpnInterface}" oifname "${lanInterface}" accept
            iifname "${lanInterface}" oifname "${vpnInterface}" accept

            # Only reached if br_netfilter gets loaded (container runtime);
            # it would then drop what L2 forwards anyway.
            iifname "${lanInterface}" oifname "${lanInterface}" accept
          '';
        };

        # No port is global on a gateway, only public: a rule without
        # `iifname` lands on the WAN. The 2026-09 audit found that same slip
        # three times, once masked by a `mkForce [ ]` in one host file.
        assertions = [
          {
            assertion = globalPorts == [ ];
            message = ''
              Gateway ${host.hostname} opens ports on every interface, WAN included: ${lib.concatStringsSep ", " globalPorts}.
              Move them under networking.firewall.interfaces.${lanInterface}
              (zone) or .${vpnInterface} (tailnet); a deliberately public port
              goes on the WAN interface, with a comment saying why.
            '';
          }
        ];

        #--------------------------------------------------------------------------
        # dnsmasq updates
        #--------------------------------------------------------------------------

        # If headscale is enabled but not adguardhome, we must have fallback DNS
        # servers to contact headscale coordination server. (wip)
        services.dnsmasq.settings = lib.mkIf (hasHeadscale && (!hasAdguardHome)) {

          # no-resolv is false because tailscale client updates the resolv file.
          no-resolv = false;

          # DNS upstreams are headscale DNS upstreams.
          server = config.services.headscale.settings.dns.nameservers.global;
        };
      }

      #--------------------------------------------------------------------------
      # Backup links (failover uplinks)
      #--------------------------------------------------------------------------

      (lib.mkIf hasBackupLinks {
        assertions = [
          {

            # The WAN lease and its `40-<wan>` networkd file come from there.
            assertion = config.darkone.service.dnsmasq.enable;
            message = "Gateway ${host.hostname}: backupLinks require darkone.service.dnsmasq (it owns the WAN DHCP).";
          }
        ]
        ++ map (message: {
          assertion = false;
          message = "Gateway ${host.hostname}: ${message}.";
        }) uplinkConflicts;

        # Untrusted networks: take the route, nothing else from their DHCP.
        systemd.network.networks = {
          ${dnfLib.primaryNetworkFile wanInterface}.dhcpV4Config.RouteMetric = dnfLib.primaryMetric;
        }
        // lib.listToAttrs (
          map (
            u:
            lib.nameValuePair u.networkFile {
              matchConfig.Name = u.interface;
              DHCP = "ipv4";
              networkConfig = {
                IPv6AcceptRA = false;
                LinkLocalAddressing = "no";
              };
              dhcpV4Config = {
                RouteMetric = u.metric;
                UseDNS = false;
                UseNTP = false;
                UseHostname = false;
                UseDomains = false;
                SendHostname = false;
              };
              linkConfig.RequiredForOnline = "no";
            }
          ) backupUplinks
        );

        # The nat module masquerades a single `externalInterface` (the WAN).
        networking.nftables.tables.dnf-uplinks = {
          family = "ip";
          content = ''
            chain post {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr ${zone.networkIp}/${toString zone.prefixLength} oifname ${nftIfaceSet backupInterfaces} masquerade comment "zone -> backup links"
            }
          '';
        };
        networking.firewall.extraForwardRules = ''
          iifname "${lanInterface}" oifname ${nftIfaceSet backupInterfaces} accept comment "zone -> backup links"
        '';

        # Loaded now: `kernel.modules_disabled` (R10) forbids it later.
        boot.kernelModules = [ "nf_conntrack_netlink" ];

        systemd.tmpfiles.rules = [ "d /run/systemd/network 0755 root root -" ];

        systemd.services.dnf-uplink-monitor = {
          description = "Zone gateway uplink probe and failover";
          wantedBy = [ "multi-user.target" ];
          wants = [ "systemd-networkd.service" ];
          after = [ "systemd-networkd.service" ];
          serviceConfig = dnfLib.mkHardenedServiceConfig { } // {
            ExecStart = monitorScript;
            Restart = "always";
            RestartSec = "5s";

            # Raw ICMP bound to a device, conntrack and `networkctl reload`
            # over D-Bus (networkd checks CAP_NET_ADMIN).
            CapabilityBoundingSet = [
              "CAP_NET_RAW"
              "CAP_NET_ADMIN"
            ];
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_NETLINK"
            ];

            # ping drops its capabilities (capset), part of `@privileged`.
            SystemCallFilter = [ "@system-service" ];
            SystemCallErrorNumber = "EPERM";

            # networkd reads drop-ins as `systemd-network`: world-readable.
            UMask = "0022";
            ReadWritePaths = [
              "-/run/systemd/network"
              "-${textfileDir}"
            ];
          };
        };
      })

      # Wifi backup links: wpa_supplicant on their radios only (hostapd keeps
      # its own). SSID and passphrase exist only in the rendered template.
      (lib.mkIf hasWifiLinks {
        networking.wireless = {
          enable = true;
          interfaces = wifiInterfaces;
          extraConfigFiles = [ config.sops.templates.${wpaTemplate}.path ];
        };

        sops.secrets = lib.listToAttrs (
          lib.concatMap (
            name:
            map (field: lib.nameValuePair (dnfLib.backupLinkSecret name field) { }) [
              "ssid"
              "psk"
            ]
          ) wifiLinkNames
        );

        # Standby radios: the monitor writes /dev/rfkill, hidden by
        # `PrivateDevices`. `-`: no rfkill, no standby, failover still runs.
        systemd.services.dnf-uplink-monitor.serviceConfig = {
          BindPaths = [ "-/dev/rfkill" ];
          DeviceAllow = [ "/dev/rfkill rw" ];
        };

        sops.templates.${wpaTemplate} = {
          content = dnfLib.mkWpaNetworks {
            inherit (cfg) backupLinks;
            placeholder = name: field: config.sops.placeholder.${dnfLib.backupLinkSecret name field};
          };
          owner = "wpa_supplicant";
          mode = "0400";
          restartUnits = map (i: "wpa_supplicant-${i}.service") wifiInterfaces;
        };
      })

      # Activate services declared in host.services via modules.nix triggers.
      (dnfLib.triggerProfileServices profileServicesArgs)
      { assertions = dnfLib.mkHostProfileServicesAssertions profileServicesArgs; }
    ]
  );
}
