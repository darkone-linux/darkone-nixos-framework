# Service test: ncps on a "server" profile host (core + real sops).
#
# Coverage:
#   - ncps.service (main unit) is active
#   - every loaded ncps-* unit reports active
#   - the JSON status endpoint returns HTTP 200 on port 8501
#
# Out of scope here (covered elsewhere or optional):
#   - harmonia: not deployed in this test (ncps uses public caches as upstream)
#   - caddy reverse proxy: lives on gateway
#   - client-side substituters config: tested implicitly by ncps running

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-server-ncps";
  workspace = ../../workspaces/node/configs/server-ncps;
  host = "server1";

  # ncps defaults to --server-addr ":8501" (0.0.0.0), so no lan needed.

  testScript = ''
    start_all()
    server1.wait_for_unit("multi-user.target")

    # Hard deps from the ncps module body.
    for unit in ["ncps.service"]:
        server1.wait_for_unit(unit)
        server1.succeed(f"systemctl is-active {unit}")

    # Auto-discovery: every loaded ncps-* unit must be green.
    server1.succeed(
        "set -e; "
        "for u in $(systemctl list-units 'ncps-*.service' "
        "--no-legend --plain | awk '{print $1}'); do "
        "  systemctl is-active --quiet \"$u\" "
        "    || { systemctl status \"$u\" --no-pager; exit 1; }; "
        "done"
    )

    # HTTP entrypoint: ncps serves JSON on 0.0.0.0:8501.
    server1.wait_for_open_port(8501)
    server1.wait_until_succeeds(
        "curl -fsSL -o /dev/null -w '%{http_code}' "
        "http://localhost:8501/ | grep -q '^200$'"
    )
  '';
}
