#!/usr/bin/env bash
#
# Lists `config/workarounds.nix` with each entry's upstream status, run by
# `just workarounds`:
#
# - `upstream`: PR or issue state via `gh`; a merged nixpkgs PR is checked
#   against the locked nixpkgs revision;
# - `package`: evaluated on the locked nixpkgs (default config: broken,
#   insecure and unfree refused), then looked up in cache.nixos.org.
#
# The `drop?` hint is a lead, `dropWhen` decides. Needs nix and jq; without
# an authenticated gh, upstream states are skipped.

set -euo pipefail

dnf=$(cd "${1:?usage: workarounds.sh <dnf dir>}" && pwd -P)
cache=https://cache.nixos.org

if [ -t 1 ]; then
  bold=$'\e[1m' dim=$'\e[2m' green=$'\e[32m' yellow=$'\e[33m' normal=$'\e[0m'
else
  bold='' dim='' green='' yellow='' normal=''
fi

# One evaluation for every entry: the locked revision, each package probed on
# unstable (and on stable for pins). `tryEval` catches problem refusals.
# shellcheck disable=SC2016 # Nix interpolations, not shell ones
report=$(DNF_ROOT="$dnf" nix eval --impure --json --expr '
  let
    dnf = builtins.getEnv "DNF_ROOT";
    flake = builtins.getFlake "path:${dnf}";
    inherit (flake.inputs.nixpkgs) lib;
    system = builtins.currentSystem;
    unstable = import flake.inputs.nixpkgs { inherit system; };
    stable = import flake.inputs.nixpkgs-stable { inherit system; };

    refusal = p:
      if p.meta.broken or false then "broken"
      else if (p.meta.knownVulnerabilities or [ ]) != [ ] then "insecure"
      else if lib.any (l: builtins.isAttrs l && !(l.free or true)) (lib.toList (p.meta.license or [ ]))
      then "unfree"
      else "dependency refused";

    probe = set: path:
      let
        p = lib.attrByPath (lib.splitString "." path) null set;
        out = builtins.tryEval p.outPath;
      in
      if p == null then { status = "absent"; }
      else if out.success then { status = "ok"; version = p.version or ""; out = out.value; }
      else { status = refusal p; version = p.version or ""; };

    withProbes = e:
      e // lib.optionalAttrs (e ? package) (
        { unstable = probe unstable e.package; }
        // lib.optionalAttrs (e.kind == "pin") { stable = probe stable e.package; }
      );
  in
  {
    rev = flake.inputs.nixpkgs.rev;
    entries = lib.mapAttrs (_: withProbes) (import "${dnf}/config/workarounds.nix");
  }
')
rev=$(jq -r .rev <<<"$report")

ghOk=false
gh auth status >/dev/null 2>&1 && ghOk=true

# `owner/repo#N` → one-line state; prints `drop?` on a 2nd line when the fix
# is already in the locked nixpkgs.
upstreamState() {
  local repo=${1%#*} n=${1##*#} issue pr sha cmp
  $ghOk || { echo "unknown (gh unavailable)"; return; }
  issue=$(gh api "repos/$repo/issues/$n" 2>/dev/null) || { echo "unknown (gh api failed)"; return; }
  if ! jq -e .pull_request >/dev/null <<<"$issue"; then
    echo "issue $(jq -r .state <<<"$issue")"
    return
  fi
  pr=$(gh api "repos/$repo/pulls/$n")
  if [ "$(jq -r .merged <<<"$pr")" != true ]; then
    echo "PR $(jq -r 'if .draft then "\(.state) (draft)" else .state end' <<<"$pr")"
    return
  fi
  if [ "$repo" != NixOS/nixpkgs ]; then
    echo "PR merged"
    return
  fi

  # `compare/<merge>...<lock>`: `ahead` or `identical` = the lock holds it.
  sha=$(jq -r .merge_commit_sha <<<"$pr")
  cmp=$(gh api "repos/NixOS/nixpkgs/compare/$sha...$rev?per_page=1" --jq .status 2>/dev/null || echo unknown)
  case $cmp in
    ahead | identical) printf 'PR merged, in the locked nixpkgs\ndrop?\n' ;;
    *) echo "PR merged, not in the locked nixpkgs yet" ;;
  esac
}

# Field of the current entry `$e`, empty when absent.
field() { jq -r "$1 // empty" <<<"$e"; }

total=0
candidates=0
while IFS= read -r id; do
  e=$(jq -c --arg id "$id" '.entries[$id]' <<<"$report")
  kind=$(field .kind)
  hint=keep
  lines=()

  lines+=("why       $(field .reason)")
  if [ -n "$(field .upstream)" ]; then
    state=$(upstreamState "$(field .upstream)")
    [ "$(tail -n1 <<<"$state")" = "drop?" ] && hint="drop?"
    lines+=("upstream  $(field .upstream): $(head -n1 <<<"$state")")
  fi

  if [ -n "$(field .package)" ]; then
    status=$(field .unstable.status)
    version=$(field .unstable.version)
    built=""
    if [ "$status" = ok ]; then
      if nix path-info --store "$cache" "$(field .unstable.out)" >/dev/null 2>&1; then
        built=yes
        status="built by Hydra"
      else
        status="not built by Hydra"
      fi
    fi
    line="unstable  $(field .package) $version: $status"

    # A pin is droppable once unstable builds and has caught up with stable.
    if [ "$kind" = pin ] && [ -n "$(field .stable.version)" ]; then
      line+=" ${dim}(stable $(field .stable.version))${normal}"
      if [ -n "$built" ] && [ "$(printf '%s\n' "$(field .stable.version)" "$version" | sort -V | tail -n1)" = "$version" ]; then
        hint="drop?"
      fi
    elif [ -n "$built" ]; then
      hint="drop?"
    fi
    lines+=("$line")
  fi

  lines+=("drop      when $(field .dropWhen)")
  lines+=("files     $(field '.files | join(", ")')")
  inputs=$(field '(.inputs // []) | join(", ")')
  [ -z "$inputs" ] || lines+=("inputs    $inputs")

  if [ "$hint" = keep ]; then
    color=$green
  else
    color=$yellow
    candidates=$((candidates + 1))
  fi
  total=$((total + 1))
  printf '%s%s%s %s· %s · since %s%s  %s[%s]%s\n' \
    "$bold" "$id" "$normal" "$dim" "$kind" "$(field .since)" "$normal" "$color" "$hint" "$normal"
  printf '  %s\n' "${lines[@]}"
  echo
done < <(jq -r '.entries | keys[]' <<<"$report")

$ghOk || echo "${yellow}gh unavailable: upstream states skipped (gh auth login)${normal}"
echo "${bold}$total workarounds, $candidates drop candidate(s)${normal} ${dim}(locked nixpkgs ${rev:0:10})${normal}"
