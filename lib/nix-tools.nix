# DNF — pure helpers for Nix tooling whose build is tied to a Nix version.
#
# `nix-eval-jobs` links `libnixexpr`: a binary built against another Nix minor
# hashes a consumer repository holding a git submodule differently, and every
# host then fails to evaluate with `mismatch in field 'narHash'`. nixpkgs
# unstable tracks the newest Nix, `nixpkgs-stable` the one NixOS ships, so the
# matching build is picked from the candidates rather than assumed.
#
# :::note
# Helpers compare `version` strings only, so they unit-test with plain
# attrsets (`{ version = "2.35.3"; }`) instead of real derivations.
# :::

{ lib }:

{

  # First candidate sharing the `X.Y` of `nix`, else the first one: a fleet
  # whose Nix matches no candidate must still evaluate, with the assertion of
  # `darkone.admin.fleet-update` to say what to fix.
  pickForNix =
    { candidates, nix }:
    let
      wanted = lib.versions.majorMinor nix.version;
      matches = package: lib.versions.majorMinor package.version == wanted;
    in
    lib.findFirst matches (lib.head candidates) candidates;

  # Whether a package is built against the same Nix minor.
  matchesNix =
    { package, nix }: lib.versions.majorMinor package.version == lib.versions.majorMinor nix.version;
}
