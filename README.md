# Darkone NixOS Framework

- [The official documentation](https://darkone-linux.github.io)
- [The french readme with the todo list](README.fr.md)

## A multi-user, multi-host, ready-to-use NixOS configuration

- Simplified [high-level configuration](https://github.com/darkone-linux/darkone-nixos-framework/blob/main/usr/config.yaml).
- Consistent and modular [structure](https://darkone-linux.github.io/doc/introduction/#structure).
- Ready-to-use [modules, profiles and tools](https://darkone-linux.github.io/ref/modules/).
- Organization designed for scalability.

> [!NOTE]
> This project is constantly evolving according to my needs.
> If you'd like to be informed about upcoming stable versions, 
> please let me know on [GitHub](https://github.com/darkone-linux/darkone-nixos-framework) 
> or by subscribing to my [YouTube channel](https://www.youtube.com/@DarkoneLinux) (FR).
> Thank you!

## Main features

- **Easy and full VPN** with [headscale](https://headscale.net/) / [tailscale](https://tailscale.com/).
- **[Multi-hosts and multi-users](https://darkone-linux.github.io/doc/specifications/#the-generator)**, deployed with [colmena](https://github.com/zhaofengli/colmena) and [just](https://github.com/casey/just).
- **Full automated host install** with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) and [disko](https://github.com/nix-community/disko).
- **[Host profiles](https://darkone-linux.github.io/ref/modules/#-darkonehostdesktop)** for servers, containers, network nodes and workstations.
- **[User profiles](https://github.com/darkone-linux/darkone-nixos-framework/tree/main/dnf/homes)** with [home manager](https://github.com/nix-community/home-manager) providing complete configurations for various users.
- **[High-level modules](https://darkone-linux.github.io/ref/modules)** 100% functional with a simple `.enable = true`.
- **[Extensible](https://darkone-linux.github.io/doc/introduction/#structure)**, scalable, consistent, customizable architecture.
- **User profiles management** with [home manager](https://github.com/nix-community/home-manager) + [home profiles](https://github.com/darkone-linux/darkone-nixos-framework/tree/main/dnf/homes).
- **[Automatic homepage + reverse proxy](https://darkone-linux.github.io/ref/modules/#-darkoneservicehomepage)** with [Homepage](https://github.com/gethomepage/homepage) and [Caddy](https://github.com/caddyserver/caddy), based on activated services.
- **[Cross-configuration](https://github.com/darkone-linux/darkone-nixos-framework/blob/main/usr/config.yaml)** to ensure network consistency.
- **Easy and reliable security**, a single password to unlock, with [sops](https://github.com/Mic92/sops-nix).
- **No-conf DNS, DHCP, reverse-proxy, firewall** and all network plumbing.

## One configuration, a full network

![New network architecture](doc/src/assets/reseau-darkone-2.png)

## Just commands

```
Available recipes:
    [apply]
    apply on what='switch'                         # Apply configuration using colmena [alias: a]
    apply-local what='switch'                      # Apply the local host configuration [alias: al]
    apply-verbose on what='switch'                 # Apply force with verbose options [alias: av]

    [check]
    check                                          # Recursive deadnix on nix files
    check-flake                                    # Check the main flake
    check-statix                                   # Check with statix

    [dev]
    cat host=''                                    # Clean + git Amend + apply-local (or on host) + Test
    clean                                          # format: fix + check + generate + format [alias: c]
    develop                                        # Launch a "nix develop" with zsh (dev env) [alias: d]
    fix                                            # Fix with statix
    format                                         # Recursive nixfmt on all nix files
    generate                                       # Update the nix generated files
    pull                                           # Pull common files from DNF repository
    push                                           # Push common files to DNF repository

    [install]
    build-iso arch="x86_64-linux"                  # Build DNF iso image
    configure host                                 # New host: ssh cp id, extr. hw, clean, commit, apply
    configure-admin-host                           # Framework installation on local machine (builder / admin)
    copy-hw host                                   # Extract hardware config from host
    copy-id host                                   # Copy pub key to the node (nix user must exists)
    full-install host user='nix' ip='auto'         # New host: full installation (install, configure, apply)
    install host user='nix' ip='auto' do='install' # New host: format with nixos-everywhere + disko
    install-key host                               # New host: format with nixos-everywhere + disko
    passwd user                                    # Update a user password
    passwd-default                                 # Update the default DNF password
    push-key host                                  # Push the infrastructure key to the host

    [manage]
    enter on                                       # Interactive shell to the host [alias: e]
    fix-boot on                                    # Multi-reinstall bootloader (using colmena)
    fix-zsh on                                     # Remove zshrc bkp to avoid error when replacing zshrc
    gc on                                          # Multi garbage collector (using colmena)
    halt on                                        # Multi-alt (using colmena)
    reboot on                                      # Multi-reboot (using colmena)
```
