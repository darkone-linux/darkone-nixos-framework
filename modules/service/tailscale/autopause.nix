# DNF tailscale: roaming clients pause tailscale on a DNF zone LAN.
#
# There `--accept-dns` would hijack resolv.conf (local dnsmasq/AdGuard) and
# `--accept-routes` collide with the connected zone subnet. A NetworkManager
# dispatcher pauses tailscale on a zone LAN and resumes it elsewhere.

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
  inherit (cfg.shared) autoPauseEnable autoPauseStateFile;

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
in
{
  config = lib.mkIf (cfg.enable && autoPauseEnable) {

    # Roaming transitions: NM dispatcher re-evaluates on every network event.
    networking.networkmanager.dispatcherScripts = [
      {
        source = autoPauseScript;
        type = "basic";
      }
    ];

    # Boot in a zone: enforce once tailscaled-autoconnect ran and the LAN has an
    # IP, otherwise the autoconnect `up` leaves the VPN active on the home LAN.
    systemd.services.tailscale-autopause = {
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
    assertions = [
      {
        assertion = config.networking.networkmanager.enable;
        message = "darkone.service.tailscale.autoPauseOnLan requires networking.networkmanager.enable.";
      }
    ];
  };
}
