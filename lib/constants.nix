# DNF — shared constants
#
# Centralised values used across DNF modules and helpers, to avoid
# duplicating magic strings and paths throughout the framework.

let

  # `.internal` is the ICANN-reserved private-use TLD: never resolvable on the
  # public Internet, so a roaming host outside any zone gets an instant NXDOMAIN.
  roamingDomain = "dnf.internal";
in
{
  # Caddy storage directory (TLS certificates, ACME state).
  # Synced between hosts by the tailscale subnet gateway, see
  # `service/tailscale.nix`.
  caddyStorage = "/var/lib/caddy/storage";

  # Zone-neutral DNS namespace: every zone's DNS answers the same names with
  # its own service IPs, so a nomadic host always reaches the caches of the
  # zone it is plugged into. Served by `service/dnsmasq.nix`, consumed by
  # `service/nix-cache.nix` (roaming clients).
  inherit roamingDomain;
  nixCacheRoamingFqdn = "nix-cache.${roamingDomain}";
  harmoniaRoamingFqdn = "harmonia.${roamingDomain}";

  # MagicDNS namespace of tailnet nodes (headscale `base_domain`), answered by
  # every node's tailscaled on the quad-100 address, gateways included.
  tailnetDomain = "tailnet.internal";
  magicDnsAddress = "100.100.100.100";

  # Tailnet IPv4 range: headscale's default `prefixes.v4`.
  tailnetIpv4Cidr = "100.64.0.0/10";

  # Reserved zone name for the global (Internet-facing) network.
  # Hosts outside this zone are considered local and reachable through a
  # zone gateway.
  globalZone = "www";

  # Network interface used for LAN traffic on a zone gateway.
  lanInterface = "lan0";

  # Network interface used by the tailscale client.
  vpnInterface = "tailscale0";

  # Public anycast resolvers answering ICMP: "is Internet reachable" witnesses
  # for `ZoneInternetDown` and the gateway backup-link probe. IP literals, so
  # a probe never depends on the DNS path it is judging.
  internetProbeTargets = [
    "1.1.1.1"
    "9.9.9.9"
  ];
}
