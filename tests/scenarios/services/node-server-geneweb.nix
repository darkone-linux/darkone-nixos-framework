# Service test: GeneWeb on a "server" host (core + real sops).
#
# Coverage:
#   - `geneweb.service` (main unit) is active
#   - every loaded `geneweb-*` unit is active: catches an upstream unit split
#     without pinning a nixpkgs revision
#   - the service answers HTTP on port 2317
#
# Out of scope (covered elsewhere, or optional):
#   - caddy reverse proxy: lives on the gateway in the real topology
#   - genealogy bases: `services.geneweb.databases` is empty here, hence no
#     `geneweb-init.service` to wait for. Enable it to cover the declarative
#     initialisation.
#
# Boots server1 only; gw1 stays data-only.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-server-geneweb";
  workspace = ../../workspaces/node/configs/server-geneweb;
  host = "server1";

  # `services.geneweb.interface` defaults to null: gwd listens on every
  # interface, no need for `lan = true`.

  testScript = ''
    start_all()

    server1.wait_for_unit("multi-user.target")

    # Main unit of the upstream module.
    server1.wait_for_unit("geneweb.service")
    server1.succeed("systemctl is-active geneweb.service")

    # Auto-discovery: every loaded `geneweb-*` unit must be green. Covers a
    # possible split (e.g. `geneweb-init.service`) without pinning nixpkgs.
    server1.succeed(
        "set -e; "
        "for u in $(systemctl list-units 'geneweb-*.service' "
        "--no-legend --plain | awk '{print $1}'); do "
        "  systemctl is-active --quiet \"$u\" "
        "    || { systemctl status \"$u\" --no-pager; exit 1; }; "
        "done"
    )

    # HTTP entrypoint: gwd listens on 2317 by default. The root serves the
    # base selection page (200 even without any declared base).
    server1.wait_for_open_port(2317)
    server1.wait_until_succeeds(
        "curl -fsSL -o /dev/null -w '%{http_code}' "
        "http://localhost:2317/ | grep -q '^200$'"
    )
  '';
}
