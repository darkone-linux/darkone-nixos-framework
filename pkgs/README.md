# DNF packages

Programs the fleet installs that **nixpkgs does not carry**. One directory per
package, `<name>/package.nix`, in the nixpkgs `by-name` shape.

```
pkgs/
├── default.nix          <-- package set, auto-discovered from the directories
├── overlay.nix          <-- same set as an overlay -> pkgs.<name>
└── <name>/package.nix   <-- the derivation
```

## What belongs here

| | |
|---|---|
| `pkgs/` | absent from nixpkgs, installed by hosts or users |
| `lib/overlays/` | **temporary** patch over an existing nixpkgs package, dropped once upstream is fixed |
| flake `inputs` | what the framework's own machinery needs (`dnf-generator`, `colmena`) |

> [!NOTE]
> A flake input is fetched at every evaluation, by every consumer. A package
> here is fetched only when its derivation is actually built.

## Adding a package

1. `mkdir pkgs/<name>` and write `package.nix` — plain `callPackage` form, full
   `meta` (`description`, `homepage`, `license`, `mainProgram`, `platforms`).
2. `git add` it: flakes ignore untracked files.
3. `nix build .#<name>` to fix the hashes, then `just clean`.

Nothing else to wire: `default.nix` scans the directories, and `overlay.nix` is
already applied to every host.

## Updating a package

```sh
just pkg-update <name>
```

`nix-update` rewrites `version` and the hashes in place.

## Upstreaming a package

Write it nixpkgs-ready from the start, so the migration stays a move:

```sh
git mv pkgs/<name> <nixpkgs>/pkgs/by-name/<xy>/<name>
```

Then delete the directory here. `pkgs.<name>` keeps resolving, now from the
nixpkgs tree. The `pr-nixpkgs` skill covers the PR itself.
