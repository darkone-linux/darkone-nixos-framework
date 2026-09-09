# DNF — package set for programs absent from nixpkgs.
#
# One directory per package, `<name>/package.nix`, in the nixpkgs `by-name`
# shape: upstreaming a package later is a `git mv`. Auto-discovered, so adding
# a program is creating its directory — there is no registry to keep in sync.
#
# Two consumers:
#
# - `./overlay.nix`, applied by `lib/mk-configuration.nix`, exposes every
#   entry as `pkgs.<name>` on all hosts;
# - `flake.nix` re-exports them, so `nix build .#<name>` and CI cover them.
#
# :::note[`inputs` or `pkgs/`?]
# A flake input is what the framework's own machinery needs (`dnf-generator`,
# `colmena`): fetched at every evaluation, by every consumer. `pkgs/` is what
# the fleet installs: fetched only when the derivation is actually built.
# :::

{ pkgs }:

let
  entries = builtins.readDir ./.;

  # Directories only: `README.md` and this file are not packages.
  #
  # `builtins`, not `lib`: as an overlay, the attribute NAMES here must be
  # computable without forcing `final`, and reaching `final.lib` to build them
  # closes the fixpoint on itself (infinite recursion). Only the values below
  # may touch `pkgs`.
  names = builtins.filter (name: entries.${name} == "directory") (builtins.attrNames entries);
in
builtins.listToAttrs (
  map (name: {
    inherit name;
    value = pkgs.callPackage (./. + "/${name}/package.nix") { };
  }) names
)
