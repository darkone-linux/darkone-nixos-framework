# L2 — darkone.service.dnsmasq : service + configuration end-to-end.
#
# Coverage:
#   - dnsmasq.service comes up
#   - `lan0` bridge built over eth1, carries the zone gateway IP
#   - systemd-resolved disabled (dnsmasq owns :53)
#   - the daemon binds UDP/53 (no adguardhome → no shift to 5353)
#   - the rendered config carries the hardening flags + the
#     `local=/<zone.domain>/` and `local=/dnf.internal/` non-forward rules
#   - generated host record (from `zone.extraDnsmasqSettings.host-record`)
#     resolves through dnsmasq itself
#   - NAT MASQUERADE rule installed for the zone subnet
#   - LAN ICMP echo-request accepted via extraInputRules; WAN implicitly
#     dropped (allowPing = false, no accept rule on wan)
#
# Out of scope here (covered elsewhere or optional):
#   - adguardhome interaction: minimal profile → adguardhome disabled, so
#     dnsmasq stays on :53 (no port shift to 5353).
#   - tailscale subnet mode: `coordination.enable = false` in `_smoke`.
#   - DHCP leases against a real client: needs an L3 scenario with a
#     second node on the same VLAN.
#
# :::caution[eth1 / lan0 conflict]
# The module slaves `eth1` into a `lan0` bridge. Going through
# `virtualisation.vlans = [ 1 ]` would also flip `assignIP = true` on the
# auto-generated interface (see nixos/lib/testing/network.nix), and NixOS
# rejects defined IPs on a bridge slave. We declare the NIC directly via
# `virtualisation.interfaces` with `assignIP = false` so eth1 stays
# IP-less and the bridge can claim it cleanly.
# :::

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-dnsmasq";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testModule = { pkgs, ... }: {
    darkone.service.dnsmasq.enable = true;

    virtualisation.interfaces.eth1 = {
      vlan = 1;
      assignIP = false;
    };

    # `dig` — query dnsmasq on its lan0 IP without going through resolv.conf.
    environment.systemPackages = [ pkgs.dnsutils ];
  };

  testScript = ''
    node1.wait_for_unit("multi-user.target")
    node1.wait_for_unit("dnsmasq.service")
    node1.succeed("systemctl is-active dnsmasq.service")

    # lan0 bridge is up and owns zone.gateway.lan.ip (10.10.1.1/16).
    node1.succeed("ip -o link show dev lan0")
    node1.succeed("ip -o -4 addr show dev lan0 | grep -q '10.10.1.1/16'")

    # The module disables systemd-resolved unconditionally.
    node1.fail("systemctl is-active systemd-resolved.service")

    # bind-dynamic: dnsmasq is listening on UDP/53 once lan0 is up.
    node1.wait_until_succeeds("ss -ulnp | grep -q ':53 '")

    # nixpkgs renders dnsmasq's config to a store path passed via `-C` on
    # the ExecStart line — not /etc/dnsmasq.conf. Fish it out of the unit.
    conf = node1.succeed(
        "systemctl cat dnsmasq.service | "
        "grep -oE -- '-C [^ ]+' | awk '{print $2}'"
    ).strip()

    # Hardening flags from the module body must reach the rendered config.
    for flag in ["bogus-priv", "domain-needed", "expand-hosts", "local-service", "bind-dynamic", "dhcp-authoritative"]:
        node1.succeed(f"grep -qE '^{flag}' {conf}")

    # Zone domain must not be forwarded upstream.
    node1.succeed(f"grep -qE '^local=/z1.test.local/' {conf}")

    # Roaming pseudo-domain answered locally too: NXDOMAIN here (no cache
    # service declared in the _smoke zone), never a forward upstream.
    node1.succeed(f"grep -qE '^local=/dnf.internal/' {conf}")
    node1.wait_until_succeeds(
        "dig +time=2 +tries=2 @10.10.1.1 nix-cache.dnf.internal | grep -q NXDOMAIN"
    )

    # NAT for the zone subnet — nftables table ip nixos-nat, chain post.
    node1.succeed("nft list chain ip nixos-nat post | grep -q '10.10.0.0/16'")

    # LAN-side ICMP echo-request accepted via extraInputRules; WAN is
    # implicitly dropped (allowPing = false, no accept on wan).
    node1.succeed("nft list chain inet nixos-fw input-allow | grep -qE 'iifname .lan0.*icmp type echo-request accept'")

    # The generated host-record in zone.extraDnsmasqSettings must resolve
    # through dnsmasq on its LAN IP — exercises the full eval → render →
    # serve chain.
    node1.wait_until_succeeds(
        "dig +short +time=2 +tries=2 @10.10.1.1 node1.z1.test.local | grep -q '^10.10.1.1$'"
    )
  '';
}
