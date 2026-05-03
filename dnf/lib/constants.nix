# DNF — shared constants
#
# Centralised values used across DNF modules and helpers, to avoid
# duplicating magic strings and paths throughout the framework.

{
  # Caddy storage directory (TLS certificates, ACME state).
  # Synced between hosts by the tailscale subnet gateway, see
  # `service/tailscale.nix`.
  caddyStorage = "/var/lib/caddy/storage";

  # Reserved zone name for the global (Internet-facing) network.
  # Hosts outside this zone are considered local and reachable through a
  # zone gateway.
  globalZone = "www";

  # Network interface used for LAN traffic on a zone gateway.
  lanInterface = "lan0";

  # Network interface used by the tailscale client.
  vpnInterface = "tailscale0";
}
