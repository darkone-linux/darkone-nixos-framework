# Service test: immich on a "server" profile host (core + real sops).
#
# Coverage:
#   - immich-server (main unit) is active
#   - postgresql (hard runtime dep) is active
#   - every loaded `immich-*` unit reports active — catches an upstream
#     `immich-microservices.service` split without pinning a nixpkgs version
#   - the SPA homepage returns HTTP 200 on host.ip:2283
#
# Out of scope here (covered elsewhere or optional):
#   - caddy reverse proxy: lives on the gateway in real DNF topology, not
#     on the immich host.
#   - kanidm: the module registers an oauth2 client template under
#     `darkone.service.idm.oauth2.immich` but kanidm is not enabled here.
#   - redis: gated by `darkone.service.immich.enableRedis` (default false).
#   - machine learning: gated by `enableMachineLearning` (default false).
#
# Boots server1 only; the zone's gateway (gw1) is data-only.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-server-immich";
  workspace = ../../workspaces/node/configs/server-immich;
  host = "server1";

  # Immich pins its HTTP bind to `host.ip` (10.10.1.2). Bring up the zone
  # VLAN so that IP actually exists on eth1 — otherwise the server crash-
  # loops on EADDRNOTAVAIL.
  lan = true;

  testScript = ''
    start_all()

    server1.wait_for_unit("multi-user.target")

    # Hard deps from the immich module body.
    for unit in ["postgresql.service", "immich-server.service"]:
        server1.wait_for_unit(unit)
        server1.succeed(f"systemctl is-active {unit}")

    # Auto-discovery: every loaded immich-* unit must be green. Catches an
    # immich-microservices split if the nixpkgs version exposes one, without
    # pinning the test to a specific upstream layout.
    server1.succeed(
        "set -e; "
        "for u in $(systemctl list-units 'immich-*.service' "
        "--no-legend --plain | awk '{print $1}'); do "
        "  systemctl is-active --quiet \"$u\" "
        "    || { systemctl status \"$u\" --no-pager; exit 1; }; "
        "done"
    )

    # HTTP entrypoint: immich binds on host.ip (services.immich.host = 10.10.1.2).
    # The SPA serves the index on / once the DB migration completes.
    server1.wait_for_open_port(2283, "10.10.1.2")
    server1.wait_until_succeeds(
        "curl -fsS -o /dev/null -w '%{http_code}' "
        "http://10.10.1.2:2283/ | grep -q '^200$'"
    )
  '';
}
