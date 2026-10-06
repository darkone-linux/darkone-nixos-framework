# Temporary overlay: exposes `pkgs.geneweb` from nixpkgs PR #522751 until it
# lands in `nixos-unstable`.
#
# :::tip[Cleanup]
# Drop it once the PR is merged: without the `nixpkgs-geneweb` input of
# `flake.nix` this file is dead, and the main `nixpkgs` tree provides
# `pkgs.geneweb`.
# :::

{ nixpkgs-geneweb }:

system: _final: _prev:
let

  # The PR tree for this `system`. `allowUnfree` follows the framework policy
  # (cf. `nixpkgsFor` in `mk-configuration.nix`).
  pkgs-geneweb = import nixpkgs-geneweb {
    inherit system;
    config.allowUnfree = true;
  };
in
{

  # Its 3 OCaml deps (calendars, unidecode, not-ocamlfind) come through the
  # `geneweb` closure: no top-level exposure needed.
  inherit (pkgs-geneweb) geneweb;
}
