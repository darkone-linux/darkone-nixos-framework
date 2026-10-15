# Darkone NixOS Project

Minimal starting point for a NixOS deployment built on the
[Darkone NixOS Framework](https://github.com/darkone-linux/darkone-nixos-framework).

This project provides the structure the framework expects, a heavily
commented `etc/config.yaml` to fill in, and nothing else. No hosts, no users,
no generated files — everything is yours to declare.

## Structure

```
flake.nix           Consumer flake (delegates everything to dnf)
Justfile            Recipes (imports dnf/just/project.just)
etc/config.yaml     Single source of truth — edit this file first
usr/                Your local overlay
  modules/          Extra NixOS modules for this deployment
  home/             Home-manager overlay, custom user profiles
  users/<login>/    Per-user customizations (one dir per declared user)
  machines/<host>/  Per-host files: configuration.nix, install/, hardware/
  secrets/          SOPS secrets and deploy key (never edited by hand)
var/generated/      Generator output — commit it, never edit it
dnf/                Symlink to the framework tree (created by `nix run .#init`)
```

## Getting started

### 1. Create your repository

```sh
nix flake new -t github:darkone-linux/darkone-nixos-framework my-network
cd my-network && git init && git add -A
```

Or from the [GitHub template](https://github.com/darkone-linux/dnf-boilerplate)
(*Use this template*). Everything below happens inside the repository.

### 2. Bootstrap

```sh
# Link dnf/ -> the framework tree in the nix store
nix run github:darkone-linux/darkone-nixos-framework#init

# Enter a shell exposing dnf-generator, colmena, sops, just, nixfmt, statix…
nix develop github:darkone-linux/darkone-nixos-framework
```

`just --list` now shows every framework recipe (groups `apply`, `check`,
`dev`, `install`, `manage`).

> [!NOTE]
> The `dnf/` symlink is what gives `just` its recipes and `dnf-generator` the
> profiles it resolves on disk. It is gitignored. Once your project has its own
> `flake.lock`, refresh it with `nix run .#init` — that form follows the
> framework revision *your* lock pins, so tooling and built system never drift.

### 3. Initialize the admin secrets

```sh
just configure-admin-host
```

Idempotent: creates the `nix` deploy key, the age keys, `.sops.yaml`, a default
password and the internal secrets of the declared services; never recreates
what exists. Re-run it after adding a service, a host or a user.

### 4. Describe your deployment

Everything is declared in `etc/config.yaml` (network, zones, users, hosts).
Comments describe every field. A first workstation needs a zone, a user and a
host — every host belongs to a zone (or carries a public `ipv4`):

```yaml
zones:
  main:
    description: "Main network"
    ipPrefix: "10.0"          # this zone uses 10.0.0.0/16

users:
  alice:
    uid: 1000
    name: "Alice"
    profile: "nix-admin"
    groups: ["global"]

hosts:
  - hostname: "poste"
    name: "Admin workstation"
    zone: "main:1.10"         # fixed IP 10.0.1.10 ("main" alone = DHCP)
    profile: "desktop"
    users: ["alice"]
    disko:
      profile: "btrfs-1-disk"
      devices:
        main: "/dev/nvme0n1"
```

Then regenerate and check:

```sh
just generate      # var/generated/*.nix, usr/users/<login>/, usr/machines/<host>/
just check-flake   # nix flake check
git add . && git commit -m "First host"
```

> [!IMPORTANT]
> Commit before building. Nix flakes only see files git tracks: an untracked
> `var/generated/hosts.nix` or `usr/machines/<host>/` makes every build fail.

### 5. Install the first host

```sh
just build-iso                 # framework ISO, carrying your deploy key
# burn it, boot the machine on it, note its IP
just full-install poste        # install + configure + first deployment
```

`full-install` chains `just install` (nixos-anywhere + disko),
`just configure` (hardware extraction, key push) and `just apply-verbose`.
Each step can be run on its own if something goes wrong.

The install freezes the disk layout and `system.stateVersion` of the host in
`usr/machines/<host>/install/` (committed). From then on, the `disko:` block
of `etc/config.yaml` has no effect and can be removed.

### 6. Day-to-day

```sh
just apply <host>       # deploy a host (colmena)
just apply-local        # deploy the machine you are on
just enter <host>       # ssh as the nix maintenance user
just clean              # fix + check + generate + format, before committing
just update-flake       # refresh flake inputs, then: nix run .#init
```

## Framework version

`flake.nix` pins a framework release (tag); the committed `flake.lock` freezes
it together with its nixpkgs. To upgrade:

1. set the new tag in `inputs.dnf.url`;
2. `nix flake update dnf`, then commit `flake.lock`.

…or try a release without committing to it:

```sh
nixos-rebuild switch --flake .#<host> \
  --override-input dnf github:darkone-linux/darkone-nixos-framework/<tag>
```

Run `nix run .#init` after any change of the pinned revision.

## Going further

- Documentation: [EN](https://darkone-linux.github.io/en/) • [FR](https://darkone-linux.github.io/fr/)
- Framework source: <https://github.com/darkone-linux/darkone-nixos-framework>
- Reference deployment: <https://github.com/darkone-linux/dnf-example>
- Generator source: <https://github.com/darkone-linux/dnf-generator>
