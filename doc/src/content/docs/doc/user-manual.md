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
    [check]
    check                        # Recursive deadnix on nix files
    check-flake                  # Check the main flake
    check-statix                 # Check with statix

    [dev]
    apply on what='switch'       # Apply configuration using colmena
    apply-force on what='switch' # Apply with build-on-target + force repl. unk profiles
    apply-local what='switch'    # Apply the local host configuration
    clean                        # format: fix + check + generate + format
    fix                          # Fix with statix
    format                       # Recursive nixfmt on all nix files
    generate                     # Update the nix generated files

    [install]
    copy-hw host                 # Extract hardware config from host
    copy-id host                 # Copy pub key to the node (nix user must exists)
    install host                 # New host: ssh cp id, extr. hw, clean, commit, apply
    install-local                # Framework installation on local machine (builder)

    [manage]
    enter host                   # Interactive shell to the host
    gc on                        # Multi garbage collector (using colmena)
    halt on                      # Multi-alt (using colmena)
    reboot on                    # Multi-reboot (using colmena)
```
