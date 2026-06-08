# Overlay temporaire : expose `pkgs.geneweb` depuis la PR nixpkgs#522751
# tant qu'elle n'est pas mergée dans `nixos-unstable`.
#
# :::tip
# À supprimer une fois la PR fusionnée : la disparition de l'input
# `nixpkgs-geneweb` dans `flake.nix` rend ce fichier mort, et `pkgs.geneweb`
# devient naturellement fourni par le tree `nixpkgs` principal.
# :::

{ nixpkgs-geneweb }:

system: _final: _prev:
let

  # Réimport ciblé du tree PR pour ce `system`. `allowUnfree` suit la
  # politique du framework (cf. `mk-configuration.nix:nixpkgsFor`) pour que
  # la closure de `geneweb` puisse tirer ses deps OCaml sans friction.
  pkgs-geneweb = import nixpkgs-geneweb {
    inherit system;
    config.allowUnfree = true;
  };
in
{

  # Les 3 deps OCaml (calendars, unidecode, not-ocamlfind) sont tirées
  # transitivement via la closure de `geneweb` : pas d'exposition top-level
  # nécessaire.
  inherit (pkgs-geneweb) geneweb;
}
