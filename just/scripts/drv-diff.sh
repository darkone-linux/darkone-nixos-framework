#!/usr/bin/env bash
#
# Refactor guard: host toplevel derivations against two states of the
# framework, a committed revision then the `dnf/` working tree. Rule of
# AGENTS.md: a refactor leaves every `drvPath` unchanged.
#
# Usage, from the root of a co-development workspace:
#
#   drv-diff.sh [host,…] [base]
#
# - `host,…`: default, every `nixosConfigurations` entry but the install
#   images (`iso-*`, `sd-image-*`);
# - `base`: framework revision, default `HEAD` (what uncommitted changes alter).
#
# Both states are exported and read as `path:` inputs: a git input stamps its
# revision on every host (`/etc/dnf-release`), no two toplevels would match.
# The working tree is exported as a commit would take it: tracked files, new
# files not ignored. The consumer tree is the same on both sides.
#
# Resources: one evaluation at a time, `WORKERS` nix-eval-jobs workers
# (default 2), each recycled past `WORKER_MEM` MiB (default 2048).
#
# Exit: 0 identical, 1 a derivation differs or a host does not evaluate,
# 2 usage. Needs nix-eval-jobs and jq.

set -euo pipefail

fail() {
  echo "drv-diff: $*" >&2
  exit 2
}

hosts=${1:-}
base=${2:-HEAD}
workers=${WORKERS:-2}
worker_mem=${WORKER_MEM:-2048}

[ -f flake.nix ] && [ -d dnf/.git ] ||
  fail "run from the root of a co-development workspace (dnf/ checkout)."
for bin in nix-eval-jobs jq; do
  command -v "$bin" > /dev/null || fail "missing tool: $bin."
done
[[ $workers =~ ^[1-9][0-9]*$ ]] || fail "WORKERS: positive integer."
[[ $worker_mem =~ ^[1-9][0-9]*$ ]] || fail "WORKER_MEM: positive integer (MiB)."
rev=$(git -C dnf rev-parse --verify --quiet "$base^{commit}") ||
  fail "unknown framework revision: $base."
short=${rev:0:7}

# Names land in a Nix expression: hostname characters only.
names=
for host in ${hosts//,/ }; do
  [[ $host =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid host name: $host."
  names+="\"$host\" "
done

select="cfgs:
  let
    wanted = [ $names];
    isImage = name: builtins.match \"(iso|sd-image)-.*\" name != null;
    names =
      if wanted != [ ] then
        wanted
      else
        builtins.filter (name: !isImage name) (builtins.attrNames cfgs);
  in
  builtins.listToAttrs (
    map (name: {
      inherit name;
      value = cfgs.\${name}.config.system.build.toplevel;
    }) names
  )"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/base" "$tmp/tree"
git -C dnf archive "$rev" | tar -x -C "$tmp/base"

# A file deleted from the working tree stays listed while tracked: skipped.
git -C dnf ls-files -z --cached --others --exclude-standard |
  (
    cd dnf
    while IFS= read -r -d '' file; do
      if [ -e "$file" ] || [ -L "$file" ]; then
        printf '%s\0' "$file"
      fi
    done | tar -c --null --no-recursion --files-from=-
  ) | tar -x -C "$tmp/tree"

# evaluate <label> <side>: `<host> <drvPath>` lines in `<side>.drv`,
# `<host> ERROR <message>` for a host that does not evaluate.
evaluate() {
  local label=$1 side=$2
  echo "drv-diff: evaluating against $label..." >&2

  # Per-host failures are reported in the JSON stream, not by the exit code.
  nix-eval-jobs --flake ".#nixosConfigurations" \
    --override-input dnf "path:$tmp/$side" --select "$select" \
    --workers "$workers" --max-memory-size "$worker_mem" \
    > "$tmp/$side.json" 2> "$tmp/$side.err" || true
  jq -r 'if .error
    then "\(.attr) ERROR \(.error | gsub("\\s+"; " ") | .[0:300])"
    else "\(.attr) \(.drvPath)" end' "$tmp/$side.json" |
    LC_ALL=C sort > "$tmp/$side.drv"

  # Flake or expression failure: not a single line, the cause is on stderr.
  if [ ! -s "$tmp/$side.drv" ]; then
    echo "drv-diff: no host evaluated against $label:" >&2
    tail -n 5 "$tmp/$side.err" >&2
    exit 1
  fi
}

evaluate "dnf $short" base
evaluate "the working tree" tree

errors=$(
  for side in base tree; do
    sed -n "s/^\([^ ]*\) ERROR /  $side \1: /p" "$tmp/$side.drv"
  done
)
changed=$(
  awk '
    NR == FNR { base[$1] = $2; next }
    $2 != "ERROR" && base[$1] != "ERROR" && base[$1] != $2 {
      printf "  %s\n    - %s\n    + %s\n", $1, base[$1], $2
    }
  ' "$tmp/base.drv" "$tmp/tree.drv"
)

if [ -n "$errors" ]; then
  echo "drv-diff: hosts failing to evaluate (base: dnf $short, tree: working tree):"
  echo "$errors"
fi
if [ -n "$changed" ]; then
  echo "drv-diff: derivations differ (-: dnf $short, +: working tree):"
  echo "$changed"
  echo "drv-diff: compare a pair with: nix run nixpkgs#nix-diff -- <-> <+>"
fi
[ -z "$errors" ] && [ -z "$changed" ] || exit 1
echo "drv-diff: $(wc -l < "$tmp/tree.drv") host(s) identical, dnf $short → working tree."
