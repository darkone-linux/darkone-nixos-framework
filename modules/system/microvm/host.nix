# MicroVM hypervisor side: guests, routed taps, isolation.

{
  lib,
  config,
  options,
  dnfLib,
  host,
  hosts,
  zone,
  microvmGuests,
  ...
}:
let
  cfg = config.darkone.system.microvm;
  guests = lib.filter (h: microvmGuests ? ${h.hostname}) hosts;
  shareDirs = [
    "persist"
    "var-lib"
    "home"
  ];

  # Private, CGNAT (tailnet) and link-local ranges: the LAN as seen by a guest.
  privateRanges = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16";
  gatewayIp = zone.gateway.lan.ip;

  # sshd ports of the guests, as their own config declares them.
  sshPorts = lib.concatMapStringsSep ", " toString (
    lib.unique (lib.concatMap (g: g.config.services.openssh.ports) (lib.attrValues microvmGuests))
  );

  # Host side of a guest link: hypervisor address, route to the guest `/32`.
  mkTapNetwork =
    guest:
    let
      link = dnfLib.mkMicrovmLink guest;
    in
    lib.nameValuePair "30-${link.tap}" {
      matchConfig.Name = link.tap;
      address = [ "${host.ip}/32" ];
      routes = [ { Destination = "${guest.ip}/32"; } ];
      linkConfig.RequiredForOnline = "no";
    };
in
{

  # `microvm.*` only exists where mk-configuration imports the host module.
  config = lib.optionalAttrs (options ? microvm.host) (
    lib.mkIf (guests != [ ]) {

      # A guest builds its share sources and `space-init` its key path from its
      # own `stateDir`: one value on each side, or virtiofsd finds no directory.
      assertions =
        lib.mapAttrsToList (name: guest: {
          assertion = guest.config.darkone.system.microvm.stateDir == cfg.stateDir;
          message = "${host.hostname}: microVM guest `${name}` must keep its hypervisor's `darkone.system.microvm.stateDir` (${cfg.stateDir}).";
        }) microvmGuests
        ++ [

          # Guests query the gateway DNS through the forward chain; on the
          # gateway itself, the `input` chain below drops them.
          {
            assertion = !(dnfLib.isGateway host zone);
            message = "${host.hostname}: a zone gateway cannot be a microVM hypervisor, its guests would lose the zone DNS.";
          }

          # Networkd host with a static resolver entry: NetworkManager would
          # stack its own DNS entries and wait-online beside them.
          {
            assertion = !config.networking.networkmanager.enable;
            message = "${host.hostname}: a microVM hypervisor runs on systemd-networkd, without NetworkManager.";
          }
        ];

      # `vms.<name>.autostart` defaults to true: every guest boots with the host.
      # `restartIfChanged` defaults to false with `evaluatedConfig`: without it
      # a deploy installs a changed guest but leaves the old one running.
      microvm = {
        vms = lib.mapAttrs (_: guest: {
          evaluatedConfig = guest;
          restartIfChanged = true;
        }) microvmGuests;
        inherit (cfg) stateDir;
      };

      # Lower layer of the guests' store overlay: `nix-store --optimise` swaps
      # its files for hardlinks, overlayfs then answers ESTALE in a running
      # guest. GC is harmless: it only drops paths no running guest uses.
      nix.optimise.automatic = lib.mkForce false;

      # virtiofsd refuses a missing source directory.
      systemd.tmpfiles.rules = lib.concatMap (
        guest: map (dir: "d ${cfg.stateDir}/${guest.hostname}/${dir} 0755 root root -") shareDirs
      ) guests;

      # Shares keep guest UIDs (a guest service = some hypervisor service) and
      # a guest root can plant setuid files: root and the VMM (`microvm:kvm`)
      # traverse, nobody else. Upstream default: 0775.
      systemd.tmpfiles.settings."10-microvm" = lib.listToAttrs (
        map (dir: lib.nameValuePair dir { d.mode = lib.mkForce "0770"; }) (
          [ cfg.stateDir ] ++ map (guest: "${cfg.stateDir}/${guest.hostname}") guests
        )
      );

      # The same files, inert here: `nosuid,nodev` on a bind of itself, the VMM
      # user included, no UID shift of live data. `nofail`: a remote hypervisor
      # never stops at boot for it.
      fileSystems.${cfg.stateDir} = {
        device = cfg.stateDir;
        fsType = "none";
        options = [
          "bind"
          "nosuid"
          "nodev"
          "nofail"
        ];
      };

      # Whole host on networkd: the taps need it, and a dhcpcd uplink beside it
      # trips the upstream networkd/dhcpcd warning. The uplink falls to
      # `99-ethernet-default-dhcp`, whose `Kind = "!*"` leaves the taps out.
      networking.useNetworkd = true;
      systemd.network.networks = lib.listToAttrs (map mkTapNetwork guests);

      # Resolver path of the fleet's dhcpcd/NetworkManager hosts: resolvconf
      # entry on the zone gateway, no resolved stub. No search domain, the
      # zone resolver answers short names itself.
      services.resolved.enable = false;
      networking.nameservers = [ gatewayIp ];

      # Proxy ARP answers on the LAN for the guests' `/32` routes, which only
      # exist on the taps: the zone reaches a guest without a bridge.
      boot.kernel.sysctl = {
        "net.ipv4.conf.all.forwarding" = 1;
        "net.ipv4.conf.all.proxy_arp" = 1;
      };

      # Own table, `policy accept`: only guest traffic is judged here, any
      # other forwarding of the hypervisor (tailnet) stays untouched.
      networking.nftables.tables.dnf-microvm = {
        family = "inet";
        content = ''
          chain forward {
            type filter hook forward priority filter; policy accept;
            iifname "vm-*" jump from_guest
            oifname "vm-*" jump to_guest
          }

          # Internet + zone gateway DNS; the LAN and other guests are dropped.
          chain from_guest {
            ct state established,related accept
            meta nfproto ipv6 drop
            ip daddr ${gatewayIp} meta l4proto { tcp, udp } th dport 53 accept
            ip daddr { ${privateRanges} } drop
            accept
          }

          # Reverse proxy and monitoring live on the zone gateway. Ping and
          # sshd stay open to the fleet, like any host: `just enter` works,
          # nix key auth guards the shell.
          chain to_guest {
            ct state established,related accept
            ip saddr ${gatewayIp} accept
            icmp type echo-request accept
            tcp dport { ${sshPorts} } accept
            drop
          }

          # Hypervisor services are closed to guests, but those a guest asks
          # for (`guestInputRules`).
          chain input {
            type filter hook input priority filter; policy accept;
            iifname "vm-*" ct state established,related accept
            ${cfg.guestInputRules}
            iifname "vm-*" drop
          }
        '';
      };
    }
  );
}
