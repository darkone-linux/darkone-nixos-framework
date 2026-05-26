# Service test: forgejo on a "server" profile host (core + real sops).
#
# Coverage:
#   - forgejo (main unit) is active
#   - postgresql (hard runtime dep) is active
#   - every loaded `forgejo-*` unit reports active — catches an upstream
#     unit split without pinning a nixpkgs version
#   - the web UI returns HTTP 200 on port 3000
#
# Out of scope here (covered elsewhere or optional):
#   - caddy reverse proxy: lives on the gateway in real DNF topology, not
#     on the forgejo host.
#   - kanidm: the module registers an oauth2 client template under
#     `darkone.service.idm.oauth2.forgejo` but kanidm is not enabled here.
#   - postfix: enabled as SMTP relay but not asserted here.
#
# Boots server1 only; the zone's gateway (gw1) is data-only.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-server-forgejo";
  workspace = ../../workspaces/node/configs/server-forgejo;
  host = "server1";

  # Forgejo defaults to HTTP_ADDR = "" (0.0.0.0), so no lan needed.

  testScript = ''
    start_all()

    server1.wait_for_unit("multi-user.target")

    # Hard deps from the forgejo module body.
    for unit in ["postgresql.service", "forgejo.service"]:
        server1.wait_for_unit(unit)
        server1.succeed(f"systemctl is-active {unit}")

    # Auto-discovery: every loaded forgejo-* unit must be green. Catches an
    # upstream unit split without pinning a nixpkgs version.
    server1.succeed(
        "set -e; "
        "for u in $(systemctl list-units 'forgejo-*.service' "
        "--no-legend --plain | awk '{print $1}'); do "
        "  systemctl is-active --quiet \"$u\" "
        "    || { systemctl status \"$u\" --no-pager; exit 1; }; "
        "done"
    )

    # HTTP entrypoint: forgejo binds on 0.0.0.0:3000 by default.
    # The home handler redirects `/` (303) to the landing page; follow
    # the redirect and verify the final response is 200.
    server1.wait_for_open_port(3000)
    server1.wait_until_succeeds(
        "curl -fsSL -o /dev/null -w '%{http_code}' "
        "http://localhost:3000/ | grep -q '^200$'"
    )
  '';
}
