# DNF headscale: tailnet pivot DNS. Doc: `../headscale.nix` header.

{
  lib,
  dnfLib,
  pkgs,
  config,
  network,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.headscale;
  srv = config.services.headscale;
  inherit (cfg.shared) policy hcsTailnetIpv4;

  # Unbound view of the tagged nodes, the ones the policy lets into the zone
  # subnets. Without it a global service served from a zone resolves to the
  # public wildcard, the HCS, which only proxies HTTPS (git over ssh breaks).
  # The HCS keeps its own resolution: its tag stays out.
  machinesView = "tailnet-machines";
  machinesViewDir = "/run/unbound-tailnet-view";
  machineTags = lib.subtractLists (dnfLib.tailnetNodeTags { inherit host network; }) (
    builtins.attrNames policy.tagOwners
  );

  # `<name>.<domain>` records of the zones that point into a zone subnet: the
  # answers any zone LAN gives (generated `host-record` entries).
  localZones = lib.filter dnfLib.inLocalZone (lib.attrValues network.zones);
  inZoneSubnet = ip: lib.any (zone: lib.hasPrefix "${zone.ipPrefix}." ip) localZones;
  isGlobalName = name: builtins.match "[^.]+\\.${lib.escapeRegex network.domain}" name != null;
  zoneGlobals = lib.unique (
    lib.concatMap (
      zone:
      lib.concatMap (
        record:
        let
          fields = lib.splitString "," record;
          ip = lib.last fields;
        in
        lib.optionals (inZoneSubnet ip) (
          map (name: "\"${name}. IN A ${ip}\"") (lib.filter isGlobalName (lib.init fields))
        )
      ) (zone.extraDnsmasqSettings.host-record or [ ])
    ) localZones
  );

  # Rewritten on change only, checked before unbound reloads: a bad file must
  # never take the tailnet DNS down. headscale unreachable: last list kept.
  viewScript = pkgs.writeShellScript "unbound-tailnet-view" ''
    set -euo pipefail
    hs() { ${srv.package}/bin/headscale --config /etc/headscale/config.yaml "$@" </dev/null; }
    file=${machinesViewDir}/nodes.conf
    new=$(hs nodes list -o json | ${pkgs.jq}/bin/jq -r --argjson tags '${builtins.toJSON machineTags}' '
      [.[] | select(any((.tags // [])[]; IN($tags[])))
        | .ip_addresses[]? | select(test("^[0-9.]+$"))]
      | unique[] | "access-control-view: \(.)/32 ${machinesView}"')
    old=$(${pkgs.coreutils}/bin/cat "$file" 2>/dev/null || true)
    [ "$new" != "$old" ] || exit 0

    printf '%s\n' "$new" > "$file.tmp"
    ${pkgs.coreutils}/bin/mv -f "$file.tmp" "$file"
    if ! ${config.services.unbound.package}/bin/unbound-checkconf /etc/unbound/unbound.conf >/dev/null; then
      printf '%s\n' "$old" > "$file"
      echo "unbound-checkconf refused the new list, previous one restored" >&2
      exit 1
    fi
    ${pkgs.systemd}/bin/systemctl reload unbound.service
    echo "view ${machinesView}: $(${pkgs.gnugrep}/bin/grep -c . "$file" || true) node(s)"
  '';
in
{
  config = lib.mkIf cfg.enable {

    services.unbound = {
      enable = true;
      settings = {
        server = {
          interface = [
            "127.0.0.1"
            hcsTailnetIpv4
          ];
          access-control = [
            "127.0.0.1 allow"
            "${dnfLib.constants.tailnetIpv4Cidr} allow"
          ];
          inherit (zone.unbound) local-data;

          # `access-control-view` lines of `unbound-tailnet-view`; none yet: no match.
          include = "\"${machinesViewDir}/*.conf\"";
          harden-glue = true;
          harden-dnssec-stripped = true;
          use-caps-for-id = false;
          prefetch = true;
          edns-buffer-size = 1232;
          hide-identity = true;
          hide-version = true;
        };
        forward-zone =
          lib.mapAttrsToList
            (_: z: {
              name = "${z.domain}.";
              forward-addr = [ "${z.gateway.vpn.ipv4}" ];
            })
            (
              lib.filterAttrs (
                n: z: (lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z) && n != dnfLib.constants.globalZone
              ) network.zones
            )
          ++ [
            {
              name = ".";
              forward-addr = [
                "9.9.9.9#dns.quad9.net"
                "149.112.112.112#dns.quad9.net"
              ];
              forward-tls-upstream = true; # Protected DNS
            }
          ];

        # `view-first`: any other name resolves as for everyone.
        view = [
          {
            name = machinesView;
            view-first = true;
            local-data = zoneGlobals;
          }
        ];
      };
    };

    # Unbound must be reachable by tailnet nodes on the VPN IP. With nftables,
    # tailscale's accept rule no longer short-circuits the nixos-fw drop
    # policy: port 53 opens on the tailscale interface (access-control limits).
    networking.firewall.interfaces.${config.services.tailscale.interfaceName} = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };

    # Root: the gRPC socket is `headscale`-group only, and unbound reloads.
    # The list outlives each run (and unbound restarts), not a reboot.
    systemd.services.unbound-tailnet-view = {
      description = "Tailnet IPs of the tagged nodes for the unbound view";
      after = [
        "headscale.service"
        "unbound.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = viewScript;
        RuntimeDirectory = baseNameOf machinesViewDir;
        RuntimeDirectoryPreserve = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # IPs only change on enrollment, which triggers a run: this is a fallback.
    systemd.timers.unbound-tailnet-view = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
