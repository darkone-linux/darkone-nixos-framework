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

  # Reserved zone name for the global (Internet-facing) network.
  # Hosts outside this zone are considered local and reachable through a
  # zone gateway.
  globalZone = "www";

  # Network interface used for LAN traffic on a zone gateway.
  lanInterface = "lan0";

  # Network interface used by the tailscale client.
  vpnInterface = "tailscale0";
}
