---
title: User Manual
sidebar:
  order: 3
---

## Getting started

:::note
Work in progress
:::

Clone or fork the DNF repository and create your configuration in `usr` directory.

## Just commands

In the root folder, type `just` ([example with `just clean`](/doc/specifications/#the-generator))

```shell
❯ just
Available recipes:
    [apply]
    apply on what='switch'       # Apply configuration using colmena
    apply-force on what='switch' # Apply with build-on-target + force repl. unk profiles
    apply-local what='switch'    # Apply the local host configuration

    [check]
    check                        # Recursive deadnix on nix files
    check-flake                  # Check the main flake
    check-statix                 # Check with statix

    [dev]
    clean                        # format: fix + check + generate + format [alias: c]
    develop                      # Launch a "nix develop" with zsh (dev env)
    fix                          # Fix with statix [alias: f]
    format                       # Recursive nixfmt on all nix files
    generate                     # Update the nix generated files [alias: g]
    pull                         # Pull common files from DNF repository
    push                         # Push common files to DNF repository

    [install]
    copy-hw host                 # Extract hardware config from host
    copy-id host                 # Copy pub key to the node (nix user must exists)
    format-dnf-on host dev       # Format and install DNF on an usb key (danger)
    format-dnf-shell             # Nix shell with tools to create usb keys
    install host                 # New host: ssh cp id, extr. hw, clean, commit, apply
    install-local                # Framework installation on local machine (builder)

    [manage]
    enter host                   # Interactive shell to the host
    fix-boot on                  # Multi-reinstall bootloader (using colmena)
    fix-zsh on                   # Remove zshrc bkp to avoid error when replacing zshrc
    gc on                        # Multi garbage collector (using colmena)
    halt on                      # Multi-alt (using colmena)
    reboot on                    # Multi-reboot (using colmena)
```
