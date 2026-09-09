# Overlay form of `./default.nix`: every DNF-only package as `pkgs.<name>`.
#
# Applied through `nixpkgs.overlays` in `lib/mk-configuration.nix` (`mkNode`),
# so NixOS modules, home-manager modules (`useGlobalPkgs`) and scenario tests
# all see the same attributes.
#
# :::note[Unrelated to `lib/overlays/`]
# Those are temporary patches, each waiting on an upstream fix. This one is
# permanent until each package is upstreamed to nixpkgs — at which point its
# directory is deleted and `pkgs.<name>` keeps resolving.
# :::

final: _prev: import ./. { pkgs = final; }
