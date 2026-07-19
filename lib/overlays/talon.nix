# Overlay: expose `pkgs.talon` from the nix-community/talon-nix flake.
#
# :::note[x86_64-linux only]
# Upstream Talon only ships x86_64 binaries, so the attribute is simply
# absent on other systems. Consumers must therefore guard their usage
# (`pkgs.talon or null`), which also keeps evaluation working when the
# input is overridden by a talon-less fork.
# :::
#
# :::caution[Unfree, pinned tarball]
# The package wraps the upstream proprietary tarball; talon-nix must be
# refreshed (upstream `scrape.py download`) at each Talon release, and
# Talon's built-in auto-update cannot write into the store.
# :::

{ talon-nix }:

system: _final: _prev:
if builtins.hasAttr system talon-nix.packages then
  { talon = talon-nix.packages.${system}.default; }
else
  { }
