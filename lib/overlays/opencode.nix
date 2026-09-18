# Overlay temporaire : épingle `pkgs.opencode`/`pkgs.opencode-desktop` à
# 1.18.29 depuis `nixpkgs-opencode` (nixpkgs juste avant #561612).
#
# :::caution[Why]
# 1.18.30 plante sur chaque prompt (`SystemPrompt.environment` TypeError,
# régression upstream). 1.18.29 est la dernière version connue qui fonctionne.
# :::
#
# :::tip
# À supprimer une fois un correctif publié amont : repasser `pkgs.opencode`
# par le tree `nixpkgs` principal et retirer l'input `nixpkgs-opencode`
# (cf. `flake.nix`).
# :::

{ nixpkgs-opencode }:

system: _final: _prev:
let
  pkgs-opencode = import nixpkgs-opencode {
    inherit system;
    config.allowUnfree = true;
  };
in
{
  inherit (pkgs-opencode) opencode opencode-desktop;
}
