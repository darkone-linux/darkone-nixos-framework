# DNF just — shared bootstrap: settings, paths and recipes of every context.
#
# Imported by `dnf.just` (framework) and `project.just` (consumer). Workspace
# paths derive from `justfile_directory()`: the root of the importing project.
#
# Layout rules:
# - one file per `[group]`; private helpers shared across files in `_*.just`;
# - `source_directory()` in bootstraps only (in `project/x.just` it is `just/project`);
# - a recipe or variable exists once per bootstrap tree: just rejects redefinitions.

# `set shell` applies per-line to non-shebang recipes (each line is a separate
# `bash -euo pipefail -c "..."` invocation). Shebang recipes (`#!/usr/bin/env bash`)
# bypass this entirely and run as plain scripts — they need their own `set -euo pipefail`.
set shell := ["bash", "-euo", "pipefail", "-c"]

workDir := justfile_directory()

# `dnfDir`: framework root, a real checkout or the `dnf/` store symlink alike.
dnfDir := source_directory() / '..'
scriptsDir := source_directory() / 'scripts'
cliffConfig := scriptsDir / 'cliff.toml'
secretsDir := workDir + '/usr/secrets'
sopsSecretsFile := secretsDir + '/secrets.yaml'
sopsInfraTargetDir := '/etc/sops/age'

# Infra age key now lives outside the repo, under /etc/sops/age (restricted),
# instead of usr/secrets. It is the file sops-nix reads on every host and the
# file pushed by `push-key`. During a key rotation it transiently holds BOTH
# the new and the old identity (concatenated), with the two single keys kept
# alongside as `.cur` / `.old` sidecars (rotation-only).
sopsInfraKeyFile := sopsInfraTargetDir + '/infra.key'
sopsInfraCurKeyFile := sopsInfraTargetDir + '/infra.key.cur'
sopsInfraOldKeyFile := sopsInfraTargetDir + '/infra.key.old'
nix := 'nix --extra-experimental-features "nix-command flakes"'
logPrefix := '[ {{CYAN}}DNF{{NORMAL}} ] '

import 'common/_helpers.just'
import 'common/check.just'
import 'common/dev.just'
