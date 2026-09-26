#!/usr/bin/env bash
#
# Evaluation gate of one system, one flake output per nix process (CI: ci.yml).
#
# `nix flake check` keeps every evaluated output live in a single process: its
# peak grows with each scenario, until the runner OOM-kills it (SIGTERM, exit
# 143, no output). Here the peak is the heaviest single output.
#
# Same scope as `nix flake check --no-build --option system <system>`:
#
# - checks, packages, devShells: `drvPath`;
# - apps: `program`;
# - nixosConfigurations built for <system>: `system.build.toplevel.drvPath`.
#
# Usage: eval-flake-outputs.sh <system> [flake]

set -euo pipefail

system=${1:?usage: $0 <system> [flake]}
flake=${2:-.}

failed=()

# Names of `set` kept by `filter`; `--apply` forces a value only if asked to.
names() {
  local set=$1
  local filter=$2
  nix eval --raw "$flake#$set" --apply "set:
    builtins.concatStringsSep \" \"
      (builtins.filter (n: ($filter) set.\${n}) (builtins.attrNames set))"
}

# A failure is recorded, not fatal: one run reports every broken output.
evaluate() {
  local attr=$1
  echo "--- $attr"
  if ! nix eval --raw "$flake#$attr"; then
    echo "::error::$attr does not evaluate"
    failed+=("$attr")
  fi
  echo
}

# Evaluates `<set>.<name>.<path>` for each name kept by `filter`.
each() {
  local set=$1
  local path=$2
  local filter=${3:-_: true}
  local list

  # Assigned apart: `for n in $(names …)` would swallow a failed listing.
  list=$(names "$set" "$filter")
  for name in $list; do
    evaluate "$set.$name.$path"
  done
}

each "checks.$system" drvPath
each "packages.$system" drvPath
each "devShells.$system" drvPath
each "apps.$system" program

# Host platform read from `pkgs`: the configuration name is not a contract.
each nixosConfigurations config.system.build.toplevel.drvPath \
  "c: c.pkgs.stdenv.hostPlatform.system == \"$system\""

if [ ${#failed[@]} -gt 0 ]; then
  echo "::error::${#failed[@]} output(s) failed: ${failed[*]}"
  exit 1
fi
