#!/usr/bin/env bash
#
# Static guard of the DNF just layout, run by CI and `just check-recipes`:
#
# - every bootstrap (dnf, project, codev) parses: just itself rejects broken
#   imports, duplicates, unknown dependencies and variables;
# - every `just <word>` a recipe body runs or prints names a recipe of its own
#   bootstrap. Nested calls only resolve at runtime: nothing else catches them.
#
# Skipped: comment lines, `just --justfile|-f …` and `cd <dir> && just …`
# (another Justfile), lines marked `# codev-only` (a project branch that runs
# only on a `dnf/` checkout, where `codev.just` is imported), and the English
# words of `prose`. Needs just and jq.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bootstraps="dnf project codev"
prose="a an the that this"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rc=0

for b in $bootstraps; do
  mkdir -p "$tmp/$b"
  printf "import '%s/just/%s.just'\n" "$root" "$b" > "$tmp/$b/Justfile"
  if ! just --justfile "$tmp/$b/Justfile" --dump --dump-format json > "$tmp/$b.json" 2> "$tmp/$b.err"; then
    echo "[$b] does not parse:" >&2
    cat "$tmp/$b.err" >&2
    rc=1
  fi
done
[ "$rc" -eq 0 ] || exit "$rc"

for b in $bootstraps; do
  jq -r '(.recipes | keys[]), (.aliases | keys[])' "$tmp/$b.json" | sort -u > "$tmp/$b.names"

  # One "<recipe> <word>" line per `just <word>` of a body, interpolations dropped.
  jq -r '.recipes | to_entries[] | .key as $r | .value.body[]
    | [.[] | strings] | join("")
    | select(test("^\\s*#|# codev-only|just (--justfile|-f) |cd [^;&|]+ && just ") | not)
    | "\($r) \(.)"' "$tmp/$b.json" \
    | while read -r recipe line; do
        { grep -oE '(^|[^[:alnum:]_./-])just [[:alnum:]_][[:alnum:]_-]*' <<< "$line" || true; } \
          | awk -v r="$recipe" '{ print r, $NF }'
      done | sort -u > "$tmp/$b.calls"

  while read -r recipe word; do
    case " $prose " in *" $word "*) continue ;; esac
    grep -qxF "$word" "$tmp/$b.names" && continue
    echo "[$b] $recipe: 'just $word' names no recipe of this bootstrap" >&2
    rc=1
  done < "$tmp/$b.calls"
done

[ "$rc" -ne 0 ] || echo "just layout: $bootstraps parse, every nested call resolves."
exit "$rc"
