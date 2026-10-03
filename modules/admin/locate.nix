# Fleet host locator (`dnf-locate`): ssh finds a host wherever it is plugged.
#
# A fleet name resolves to the host's home address. Once the host roams
# (another zone, or outside on the tailnet), every `ssh nix@<host>` — colmena,
# `fleet-update`, `just enter` — would aim at that dead address. Enabled on an
# admin host, a `ProxyCommand` routes these connections through `dnf-locate`.
#
# Paths tried, all derived from the topology:
#
# - `<host>`: home address, alone first — the usual case costs one lookup;
# - `<host>.<zone domain>`: reservation each zone holds for visiting hosts;
# - `<host>.tailnet.internal`: tailnet address (zone gateways resolve it).
#
# The first path to answer on the port wins.
#
# :::caution[Fleet ranges only]
# An alternate path counts only when its address lies in its own range (zone
# subnet, tailnet). A wildcard record of the public domain resolves any name,
# and the `nix` account pins no host key: the deploy would land on a stranger.
# :::
#
# :::tip[Where is my host?]
# `dnf-locate --print <host>` prints the path that answers, or fails.
# :::

{
  lib,
  config,
  pkgs,
  dnfLib,
  host,
  hosts,
  network,
  ...
}:
let
  cfg = config.darkone.admin.locate;
  inherit (dnfLib.constants) globalZone tailnetDomain tailnetIpv4Cidr;

  localZones = lib.filterAttrs (
    name: zone: name != globalZone && (zone.networkIp or null) != null
  ) network.zones;

  # "<domain suffix> <CIDR>" per alternate path.
  paths =
    lib.mapAttrsToList (
      _: zone: "${zone.domain} ${zone.networkIp}/${toString zone.prefixLength}"
    ) localZones
    ++ lib.optional network.coordination.enable "${tailnetDomain} ${tailnetIpv4Cidr}";

  # Every other fleet host: names only, foreign hosts keep plain ssh.
  fleetHosts = lib.unique (lib.filter (name: name != host.hostname) (map (h: h.hostname) hosts));

  dnfLocate = pkgs.writeShellApplication {
    name = "dnf-locate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.getent
      pkgs.netcat-openbsd
    ];
    text = ''

      # dnf-locate [--print] HOST [PORT]
      print=false
      if [ "''${1:-}" = "--print" ]; then
        print=true
        shift
      fi
      host=''${1:?usage: dnf-locate [--print] HOST [PORT]}
      port=''${2:-22}
      paths=(${lib.escapeShellArgs paths})

      ip2int() {
        local IFS=. a b c d
        read -r a b c d <<< "$1"
        echo $(((a << 24) | (b << 16) | (c << 8) | d))
      }

      in_cidr() {
        local len=''${2#*/} mask ip net
        mask=$(((0xffffffff << (32 - len)) & 0xffffffff))
        ip=$(ip2int "$1")
        net=$(ip2int "''${2%/*}")
        (((ip & mask) == (net & mask)))
      }

      # Prints "<name> <address>" when the address answers within $2 seconds.
      # $3, the range an alternate path must resolve into (see the header).
      probe() {
        local name=$1 wait=$2 cidr=''${3:-} ip
        ip=$(getent ahostsv4 "$name" | awk 'NR == 1 { print $1 }') || true
        [ -n "$ip" ] || return 0
        if [ -n "$cidr" ] && ! in_cidr "$ip" "$cidr"; then
          return 0
        fi
        if timeout "$wait" bash -c ": < /dev/tcp/$ip/$port" 2> /dev/null; then
          echo "$name $ip"
        fi
      }

      found=$(probe "$host" 1)

      # Race every path, home included (a slow tailnet hop). `head` returns
      # on the first answer; the losing probes die on their own timeout, off
      # stderr: colmena reads ssh's through a pipe and would wait for them.
      if [ -z "$found" ]; then
        found=$(
          {
            probe "$host" 3 2> /dev/null &
            for path in "''${paths[@]}"; do
              probe "$host.''${path% *}" 3 "''${path#* }" 2> /dev/null &
            done
          } | head -n 1
        )
      fi

      if [ -z "$found" ]; then
        echo "dnf-locate: $host:$port answers on no path (home, zones, tailnet)" >&2
        exit 1
      fi
      if $print; then
        echo "''${found% *}"
      else
        exec nc "''${found#* }" "$port"
      fi
    '';
  };
in
{
  options = {
    darkone.admin.locate.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.darkone.admin.nix.enable;
      defaultText = lib.literalExpression "config.darkone.admin.nix.enable";
      description = "Route ssh to fleet hosts through `dnf-locate` (home, zone reservations, tailnet).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ dnfLocate ];

    # `%h` honours a `HostName` set by `just roaming`: the redirection wins.
    programs.ssh.extraConfig = lib.mkIf (fleetHosts != [ ]) ''
      Host ${lib.concatStringsSep " " fleetHosts}
        ProxyCommand ${lib.getExe dnfLocate} %h %p
    '';
  };
}
