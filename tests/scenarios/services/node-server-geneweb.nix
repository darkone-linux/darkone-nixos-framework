# Service test : GeneWeb sur un host "server" (core + sops réel).
#
# Couverture :
#   - `geneweb.service` (unité principale) est active
#   - toute unité `geneweb-*` chargée est active — détecte un split d'unités
#     upstream sans épingler une révision nixpkgs précise
#   - le service répond en HTTP sur le port 2317
#
# Hors scope (couvert ailleurs ou optionnel) :
#   - caddy reverse proxy : vit sur la gateway en topo réelle, pas sur le host geneweb
#   - bases généalogiques : `services.geneweb.databases` vide ici → pas de
#     `geneweb-init.service` à attendre. Activer si l'on veut couvrir
#     l'initialisation déclarative.
#
# Boote server1 uniquement ; gw1 reste data-only.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-server-geneweb";
  workspace = ../../workspaces/node/configs/server-geneweb;
  host = "server1";

  # `services.geneweb.interface` défaut = null → gwd écoute sur toutes
  # les interfaces. Pas besoin de `lan = true`.

  testScript = ''
    start_all()

    server1.wait_for_unit("multi-user.target")

    # Unité principale du module upstream.
    server1.wait_for_unit("geneweb.service")
    server1.succeed("systemctl is-active geneweb.service")

    # Auto-découverte : toute unité `geneweb-*` chargée doit être verte.
    # Couvre un éventuel split (ex. `geneweb-init.service`) sans épingler
    # de version nixpkgs.
    server1.succeed(
        "set -e; "
        "for u in $(systemctl list-units 'geneweb-*.service' "
        "--no-legend --plain | awk '{print $1}'); do "
        "  systemctl is-active --quiet \"$u\" "
        "    || { systemctl status \"$u\" --no-pager; exit 1; }; "
        "done"
    )

    # HTTP entrypoint : gwd écoute sur 2317 par défaut. La racine renvoie
    # la page de sélection des bases (200 même si aucune base déclarée).
    server1.wait_for_open_port(2317)
    server1.wait_until_succeeds(
        "curl -fsSL -o /dev/null -w '%{http_code}' "
        "http://localhost:2317/ | grep -q '^200$'"
    )
  '';
}
