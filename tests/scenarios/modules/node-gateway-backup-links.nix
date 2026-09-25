# L3 — darkone.host.gateway.backupLinks: WAN failover to a backup link.
#
# Topology (203.0.113.1 = "the Internet", a loopback address on each upstream):
#
#   client ─ vlan 1 ─ gw1 ─ eth2 / vlan 2 ─ isp     (WAN, DHCP)
#                         └ eth3 / vlan 3 ─ backup  (backup link, DHCP)
#
# Coverage:
#   - both uplinks leased, WAN preferred (metric 100), backup at 300
#   - a LAN client reaches the Internet through the WAN (nat module)
#   - WAN keeps its lease but loses the Internet: penalty drop-in written,
#     WAN metric 20100, default route on the backup link, the client still
#     reaches the Internet (masquerade of the `dnf-uplinks` table)
#   - Internet back on the WAN: penalty removed, default route back on eth2
#   - textfile metrics follow the active link; NAT flows purged on each switch
#
# Out of scope: wifi links (need mac80211_hwsim + sops fixtures), carrier loss.

{ pkgs, inputs }:
let

  # Upstream router: static address, DHCP server, "Internet" on loopback.
  upstream = { vlan, subnet }: { lib, ... }: {
    virtualisation.interfaces.eth1 = {
      inherit vlan;
      assignIP = false;
    };
    networking = {
      useDHCP = false;
      firewall.enable = false;
      interfaces.eth1.ipv4.addresses = [
        {
          address = "${subnet}.1";
          prefixLength = 24;
        }
      ];
      localCommands = "ip addr add 203.0.113.1/32 dev lo";
    };
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = false;
      settings = {
        port = 0;
        interface = "eth1";
        bind-interfaces = true;
        dhcp-range = "${subnet}.100,${subnet}.150,1h";
        dhcp-option = "option:router,${subnet}.1";
      };
    };
    virtualisation.memorySize = lib.mkDefault 512;
  };
in
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-gateway-backup-links";
  workspace = ../../workspaces/node/configs/gateway-backup-links;
  host = "gw1";

  testModule = {
    darkone.host.gateway.backupLinks.cable = {
      type = "ethernet";
      interface = "eth3";
    };

    # Fast rounds: the scenario waits seconds, not minutes.
    darkone.host.gateway.linkCheck = {
      targets = [ "203.0.113.1" ];
      interval = 2;
      failAfter = 2;
      recoverAfter = 2;
    };

    # LAN, WAN and backup NICs stay IP-less: lan0 and networkd own them.
    virtualisation.interfaces = {
      eth1 = {
        vlan = 1;
        assignIP = false;
      };
      eth2 = {
        vlan = 2;
        assignIP = false;
      };
      eth3 = {
        vlan = 3;
        assignIP = false;
      };
    };

    # Collector dir normally created by `service/monitoring.nix`.
    systemd.tmpfiles.rules = [ "d /var/lib/node-exporter-textfile 0755 root root -" ];
  };

  extraNodes = {
    isp = upstream {
      vlan = 2;
      subnet = "192.168.50";
    };
    backup = upstream {
      vlan = 3;
      subnet = "192.168.60";
    };
    client = {
      virtualisation.interfaces.eth1 = {
        vlan = 1;
        assignIP = false;
      };
      networking = {
        useDHCP = false;
        firewall.enable = false;
        interfaces.eth1.useDHCP = true;
      };
      virtualisation.memorySize = 512;
    };
  };

  testScript = ''
    wan_penalty = "/run/systemd/network/40-eth2.network.d/90-dnf-penalty.conf"
    best = "ip -4 route show default | head -n1"
    metrics = "/var/lib/node-exporter-textfile/dnf-uplinks.prom"

    start_all()
    isp.wait_for_unit("dnsmasq.service")
    backup.wait_for_unit("dnsmasq.service")
    gw1.wait_for_unit("dnf-uplink-monitor.service")

    with subtest("both uplinks leased, WAN preferred"):
        gw1.wait_until_succeeds("ip -4 route show default dev eth2 | grep -q 'metric 100'", timeout=120)
        gw1.wait_until_succeeds("ip -4 route show default dev eth3 | grep -q 'metric 300'", timeout=120)
        gw1.succeed(f"{best} | grep -q 'dev eth2'")
        gw1.succeed("nft list table ip dnf-uplinks | grep -q 'masquerade'")

    with subtest("LAN client reaches the Internet through the WAN"):
        client.wait_until_succeeds("ping -c1 -W2 203.0.113.1", timeout=120)

    with subtest("WAN loses the Internet, keeps its lease: failover"):
        isp.succeed("ip addr del 203.0.113.1/32 dev lo")
        gw1.wait_until_succeeds(f"test -e {wan_penalty}", timeout=60)
        gw1.wait_until_succeeds("ip -4 route show default dev eth2 | grep -q 'metric 20100'", timeout=60)
        gw1.wait_until_succeeds(f"{best} | grep -q 'dev eth3'", timeout=60)
        client.wait_until_succeeds("ping -c1 -W2 203.0.113.1", timeout=60)
        gw1.wait_until_succeeds(
            f"grep -q 'dnf_gateway_link_active{{interface=\"eth3\",role=\"backup\"}} 1' {metrics}",
            timeout=30,
        )
        gw1.succeed("journalctl -u dnf-uplink-monitor | grep -q 'eth2 (primary): no Internet'")

        # conntrack ran inside the hardened unit (a denial would print instead).
        gw1.succeed("journalctl -u dnf-uplink-monitor | grep -q 'flow entries have been deleted'")

    with subtest("Internet back on the WAN: failback"):
        isp.succeed("ip addr add 203.0.113.1/32 dev lo")
        gw1.wait_until_fails(f"test -e {wan_penalty}", timeout=60)
        gw1.wait_until_succeeds(f"{best} | grep -q 'dev eth2'", timeout=60)
        client.wait_until_succeeds("ping -c1 -W2 203.0.113.1", timeout=60)
        gw1.wait_until_succeeds(
            f"grep -q 'dnf_gateway_link_active{{interface=\"eth2\",role=\"primary\"}} 1' {metrics}",
            timeout=30,
        )
  '';
}
