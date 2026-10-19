# Your DNF network

Welcome! This folder **is** your network. Every machine, user and service is
described here, as code, and built from it with the
[Darkone NixOS Framework](https://github.com/darkone-linux/darkone-nixos-framework)
(DNF). Nothing on the hosts is configured by hand: change a file here, deploy,
and the machine follows.

One file to know first: **`etc/config.yaml`**. Its comments explain every
field, and your editor shows them on hover.

## What is where

| Path | What it holds |
|---|---|
| `etc/config.yaml` | Your network: zones, users, hosts, services |
| `usr/machines/<host>/` | Files of one host (`configuration.nix` is yours to edit) |
| `usr/users/<login>/` | Customizations of one user |
| `usr/modules/`, `usr/home/` | Your own NixOS and Home Manager modules |
| `usr/secrets/` | Keys and encrypted secrets: handled by `just`, never by hand |
| `var/generated/` | Written by `just generate`: commit it, never edit it |
| `dnf/` | Link to the framework release this project pins |

## Every day

Run everything from this folder (`cd /etc/nixos`):

```sh
just                  # every command, by group
just clean            # check and format, before each commit
just apply-local      # deploy this machine
just apply <host>     # deploy another host
git add -A && git commit -m "…"
```

> [!IMPORTANT]
> Commit before you build: Nix only sees the files git tracks.

## Next steps

Your admin host is ready, step 1 of 4. Then, at your own pace:

1. **The gateway**: a small always-on machine between the Internet box and the
   network: fixed addresses, local names, shared services.
   [Install the gateway](https://darkone-linux.github.io/en/doc/admin-guide/install/gateway/)
2. **Servers and services**: files, photos, chat, passwords… each one declared
   in `etc/config.yaml`.
   [The service catalog](https://darkone-linux.github.io/en/doc/admin-guide/operate/services/)
3. **The Internet**: a coordination server links your sites and publishes
   your services.
   [The coordination server](https://darkone-linux.github.io/en/doc/admin-guide/install/hcs/)

## Keep your keys safe

The keys of the whole network live on this machine. Keep the USB stick of the
backup away from it, and refresh it after any change of keys:

```sh
just backup-admin /dev/disk/by-label/<label>
```

Without the backup, a lost or broken disk loses every key of the network.

## Help

- Documentation: [English](https://darkone-linux.github.io/en/) •
  [Français](https://darkone-linux.github.io/fr/)
- First network, step by step:
  [installation guide](https://darkone-linux.github.io/en/doc/admin-guide/install/first-network-installation/)
- Updating the framework:
  [versions](https://darkone-linux.github.io/en/doc/admin-guide/maintain/versions/)
- Source code: [framework](https://github.com/darkone-linux/darkone-nixos-framework) •
  [generator](https://github.com/darkone-linux/dnf-generator) •
  [reference deployment](https://github.com/darkone-linux/dnf-example)

## Starting without the installer

The DNF installer image (`darkone new`) writes this project for you. Started
from the [GitHub template](https://github.com/darkone-linux/dnf-boilerplate)
or `nix flake new` instead:

```sh
nix flake new -t github:darkone-linux/darkone-nixos-framework my-network
cd my-network && git init -b main && git add -A
nix run .#init                # links dnf/ to the framework
```

Then describe your network in `etc/config.yaml` and install the first host:
see *Creating the project* in the
[installation guide](https://darkone-linux.github.io/en/doc/admin-guide/install/first-network-installation/).
