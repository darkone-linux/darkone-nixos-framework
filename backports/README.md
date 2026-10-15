# DNF backports

NixOS modules from **open nixpkgs PRs** the framework already relies on, copied
unchanged (but for `nixfmt -s`) below a provenance header. A copy costs one file;
sourcing the PR branch as a flake input fetched a whole nixpkgs tree at every
evaluation, on every host.

```
backports/
└── nixos/<name>.nix   <-- imported by `lib/mk-configuration.nix`, every host
```

| Module | nixpkgs PR | Package |
|---|---|---|
| `nixos/geneweb.nix` | [#522751](https://github.com/NixOS/nixpkgs/pull/522751) | fork, `lib/overlays/geneweb.nix` (fetched on GeneWeb hosts only) |
| `nixos/oxicloud.nix` | [#516113](https://github.com/NixOS/nixpkgs/pull/516113) | already in nixpkgs |

Imported on every host, like an upstream module: the DNF wrappers
(`modules/service/<name>.nix`) read their options everywhere (proxy port, data
directories).

## Dropping a backport

Once the PR lands in `nixos-unstable` and the lock follows:

1. delete `backports/nixos/<name>.nix` and its line in
   `lib/mk-configuration.nix`;
2. GeneWeb only: drop `lib/overlays/geneweb.nix` and the `nixpkgs-geneweb`
   input.

The wrapper `modules/service/<name>.nix` stays unchanged.

## Updating a backport

Copy the module again from the PR branch and keep the header, with the new
commit.
