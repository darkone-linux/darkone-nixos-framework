# AGENTS.md

Telegraph style. Framework-scoped rules for `darkone-nixos-framework` (DNF).
Skills own workflows; this file owns hard policy and routing.

## Overview

- DNF: declarative, reproducible multi-host NixOS framework for self-hosted
  home/small-business networks.
- This repo provides:
  - `nixosModules.darkone`: opinionated NixOS modules
  - `homeManagerModules.darkone`: home-manager modules
  - `lib.mkConfigurations`: assembler consumed by consumer flakes
    (arthur-network, dnf-boilerplate)
  - ISO images for fast install (`nixosConfigurations.iso-*`)
  - `libTests`: unit tests for `lib/`

## Rules

- 95% confidence before edits; else ask follow-ups.
- Read Nix file headers before editing.
- Code: clear, human-readable, with comments.

### Comments

- English; concise; explain why, not what; capture intent, constraints, non-obvious decisions.
- Never restate what the code already expresses.
- MUST: a blank line ALWAYS precedes a comment. No exceptions — applies to single-line and block comments, to Nix code and shell heredocs, and to the first comment inside `{`, `(`, `[`, or `''`. Header comments at the very top of a file are the only exception.
- If long: bullets, visual structure; not prose.
- Nix file header comment, required for Nix modules:
  - 1st line: concise description.
  - Markdown Starlight admonitions: note, tip, caution, danger.
  - Aim: use, maintain, configure, debug.

## Layout

- `lib/`: shared helpers (`dnfLib`); each helper requires a full unit test in `tests/unit/lib/`.
- `lib/mkConfigurations.nix`: assembler called by consumer flakes.
- `modules/`: NixOS modules under `modules/<type>/<name>.nix`.
- `home/`: home-manager modules (`home/modules/`), NixOS user profiles (`home/nixos/`), home profiles (`home/profiles/`).
- `hosts/`: ISO/install configs, templates.
- `tests/unit/`: Nix unit tests (run with `nix-unit`).
- `flake.nix`: framework standalone flake (exposes `lib.mkConfigurations`, modules, ISO, libTests, devShell).
- `assets/`: shared Justfile recipes (`default.just`) imported by consumer projects.

## Protected files

- Never modify `*.lock` files.
- Never modify any file whose header forbids it.

## Framework ↔ consumer boundary

- Framework modules MUST access consumer-side files (`usr/secrets/...`, `usr/www/...`, etc.) via the injected `workDir` specialArg, not via relative paths (`./../../usr/...`). The framework's flake root is not the consumer's workspace.
- New per-user/per-host paths exposed by the generator should be pre-resolved in `lib/mkConfigurations.nix` and passed via specialArgs (cf. `userNixosProfiles`).
- The framework reads only its own files via local Nix paths (`./modules`, `./home`, `./lib`); any consumer path goes through `workDir`.

## Nix Conventions

- Access `dnfLib` via injected module args; never manually import `dnf/lib/`.
- Prefer explicit functions; avoid implicit `<nixpkgs>` imports.
- Avoid global `with;` except for 8 or more items. Prefer `inherit`.
- Prefer `mkIf`/`mkMerge`; avoid imperative `if`/`else` module logic.
- Use `genAttrs`/`mapAttrs` to avoid duplication across systems.
- Master argument patterns (`@`, `...`, `defaults`) for reusable code.
- No `<nixpkgs>` import; use flake-injected pkgs (purity, reproducibility).
- No `with lib;`; use explicit `lib.x` or `inherit (lib) x`; preserves origin, eases debug.
- Multi-host: `genAttrs`/`mapAttrs` over per-host copy-paste.

## Systemd Unit Scripts

- Every external binary called from a systemd unit (`script`, `preStart`, `postStart`, `ExecStart=`) MUST be referenced by its full store path: `${pkgs.<pkg>}/bin/<cmd>`.
- Applies to standard utilities too: `awk`, `grep`, `sed`, `seq`, `sleep`, `cat`, `cp`, `mkdir`, `umount`... systemd's default PATH is empty; nothing is implicitly available.
- Common locations: `${pkgs.coreutils}/bin/{cat,cp,mkdir,seq,sleep,...}`, `${pkgs.gnugrep}/bin/grep`, `${pkgs.gawk}/bin/awk`, `${pkgs.gnused}/bin/sed`, `${pkgs.util-linux}/bin/{umount,mount,...}`.
- Shell builtins (`echo`, `[`, `for`, `if`, `set`, `read`) do not need a path.
- Do not rely on `path = [ ... ]`: full store paths make the dependency on each tool explicit and auditable in `git grep`.
