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
    [_main]
    clean            # format (nixfmt) + generate + check (deadnix)
    install          # Framework installation (wip)

    [check]
    check            # Recursive deadnix on nix files
    check-flake      # Check the main flake
    check-statix     # Check with statix

    [touch]
    fix              # Fix with statix
    format           # Recursive nixfmt on all nix files
    generate         # Update the nix generated files

    [utils]
    ssh-copy-id host # Copy local id on a new node (wip)
```
