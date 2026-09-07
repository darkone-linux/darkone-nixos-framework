#!/usr/bin/env bash
#
# Cut a release in one repository of the DNF ecosystem: bump the version file,
# prepend a generated CHANGELOG entry, commit and tag. Never pushes.
#
# Run via `just bump [level]`, which supplies `--repo` and `--config`.
#
# The version file is discovered, not declared — `VERSION` (framework),
# `Cargo.toml` (dnf-generator) or `package.json` (dnf-doc). git-cliff renders
# the version block; the file's header, `## [Unreleased]` section and
# reference-link footer are assembled here, so dnf-doc keeps the hand-written
# history it accumulated before conventional commits.
#
# Usage:
#   just-bump.sh --config <cliff.toml> [--repo <dir>] [--level <l>]
#                [--line <X.Y>] [--yes] [--dry-run]
#
#   --level   auto (default) | patch | minor | major | X.Y.Z
#             `auto` asks git-cliff for the SemVer implied by the commits.
#   --line    Pin MAJOR.MINOR to a framework line (dnf-doc): a differing line
#             jumps to <line>.0, an identical one bumps the patch.

set -euo pipefail

# Same rendering as the `_log` / `_warn` / `_err` recipes of assets/just/common.just.
log() { printf '[ \033[1;36mDNF\033[0m ] \033[1;32mBMP\033[0m • %s\n' "$*" >&2; }
warn() { printf '[ \033[1;36mDNF\033[0m ] \033[1;33mWRN\033[0m • %s\n' "$*" >&2; }
die() {
  printf '[ \033[1;36mDNF\033[0m ] \033[1;31mERR\033[0m • %s\n' "$*" >&2
  exit 1
}

repo="."
config=""
level="auto"
line=""
assumeYes=0
dryRun=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --config) config="$2"; shift 2 ;;
    --level) level="${2:-auto}"; shift 2 ;;
    --line) line="$2"; shift 2 ;;
    --yes | -y) assumeYes=1; shift ;;
    --dry-run) dryRun=1; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[ -n "$config" ] || die "Missing --config <cliff.toml>"
[ -f "$config" ] || die "Config not found: $config"
config="$(cd "$(dirname "$config")" && pwd)/$(basename "$config")"

cd "$repo" || die "No such directory: $repo"
git rev-parse --git-dir > /dev/null 2>&1 || die "Not a git repository: $repo"

for bin in git git-cliff; do
  command -v "$bin" > /dev/null 2>&1 || die "Missing required tool: $bin"
done

#==============================================================================
# Version file — read / write, dispatched on what the repo actually carries
#==============================================================================

if [ -f VERSION ]; then
  versionFile="VERSION"
elif [ -f Cargo.toml ]; then
  versionFile="Cargo.toml"
elif [ -f package.json ]; then
  versionFile="package.json"
else
  die "No version file (VERSION, Cargo.toml or package.json) in $(pwd)"
fi

readVersion() {
  case "$versionFile" in
    VERSION) tr -d '[:space:]' < VERSION ;;

    # Scoped to the `[package]` table: a `version =` under `[dependencies]`
    # sits at column 0 too.
    Cargo.toml) awk '/^\[package\]/{p=1;next} /^\[/{p=0} p&&/^version *=/{split($0,a,"\"");print a[2];exit}' Cargo.toml ;;
    package.json) jq -r '.version' package.json ;;
  esac
}

writeVersion() {
  case "$versionFile" in
    VERSION) printf '%s\n' "$1" > VERSION ;;
    Cargo.toml)
      sed -i "/^\[package\]/,/^\[dependencies\]/{s/^version *= *\".*\"/version = \"$1\"/}" Cargo.toml

      # Cargo.lock carries the crate's own version; realign it offline so the
      # commit stays self-consistent without touching any other dependency.
      command -v cargo > /dev/null 2>&1 &&
        cargo update --offline -p "$(awk '/^\[package\]/{p=1;next} /^\[/{p=0} p&&/^name *=/{split($0,a,"\"");print a[2];exit}' Cargo.toml)" \
          > /dev/null 2>&1 || true
      ;;
    package.json)
      # `npm version` also refreshes package-lock.json, which jq alone would leave stale.
      if command -v npm > /dev/null 2>&1; then
        npm version "$1" --no-git-tag-version --no-commit-hooks > /dev/null
      else
        jq --arg v "$1" '.version = $v' package.json > package.json.tmp
        mv package.json.tmp package.json
      fi
      ;;
  esac
}

#==============================================================================
# Guards — refuse to release from an ambiguous tree
#==============================================================================

# `--dry-run` inspects and writes nothing: the release guards would only stop it
# from answering the question it was asked.
if [ "$dryRun" -eq 0 ]; then
  [ -z "$(git status --porcelain)" ] || die "Working tree is dirty — commit or stash first."

  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "main" ] || die "Releases are cut from main, not '$branch'."

  if upstream="$(git rev-parse --abbrev-ref '@{u}' 2> /dev/null)"; then
    [ "$(git rev-list --count "$upstream"..HEAD)" -eq 0 ] ||
      warn "Local commits not pushed to $upstream yet."
    [ "$(git rev-list --count HEAD.."$upstream")" -eq 0 ] ||
      die "Behind $upstream — pull before releasing."
  else
    warn "No upstream branch configured."
  fi
fi

#==============================================================================
# Next version
#==============================================================================

old="$(readVersion)"
[ -n "$old" ] || die "Could not read the current version from $versionFile"

bumpPart() {
  IFS=. read -r a b c <<< "$1"
  case "$2" in
    major) printf '%d.0.0\n' "$((a + 1))" ;;
    minor) printf '%d.%d.0\n' "$a" "$((b + 1))" ;;
    patch) printf '%d.%d.%d\n' "$a" "$b" "$((c + 1))" ;;
  esac
}

case "$level" in
  auto)
    # git-cliff derives the SemVer from the commits since the last tag; it has
    # nothing to go on before the first tag, where the declared version stands.
    if git tag --list 'v[0-9]*' | grep -q .; then
      new="$(git-cliff --config "$config" --bumped-version 2> /dev/null | sed 's/^v//')"
      [ -n "$new" ] || new="$(bumpPart "$old" patch)"
    else
      new="$old"
      log "No release tag yet — taking the declared version $new."
    fi
    ;;
  major | minor | patch) new="$(bumpPart "$old" "$level")" ;;
  [0-9]*.[0-9]*.[0-9]*) new="$level" ;;
  *) die "Invalid --level: $level (auto|patch|minor|major|X.Y.Z)" ;;
esac

# `--line`: dnf-doc shares MAJOR.MINOR with the framework and owns only PATCH.
if [ -n "$line" ]; then
  case "$line" in
    [0-9]*.[0-9]*) ;;
    *) die "Invalid --line: $line (expected X.Y)" ;;
  esac
  if [ "${old%.*}" = "$line" ]; then
    new="$(bumpPart "$old" patch)"
  else
    new="$line.0"
  fi
fi

[ "$new" != "$old" ] || [ "$level" = "auto" ] ||
  die "Computed version equals the current one ($old)."
git rev-parse -q --verify "refs/tags/v$new" > /dev/null &&
  die "Tag v$new already exists."

log "Bumping $(basename "$(pwd)"): $old → $new"

#==============================================================================
# Changelog — git-cliff renders the block, this script owns the file around it
#==============================================================================

# `https://github.com/owner/repo` whatever remote form is configured.
remote="$(git remote get-url origin 2> /dev/null || echo "")"
remote="${remote%.git}"
remote="${remote/git@github.com:/https://github.com/}"
remote="${remote/ssh:\/\/git@github.com\//https://github.com/}"

block="$(git-cliff --config "$config" --unreleased --tag "v$new" 2> /dev/null)"
[ -n "$block" ] || die "git-cliff produced no entry for v$new."

changelogExisted=1
if [ ! -f CHANGELOG.md ]; then
  changelogExisted=0
  name="$(basename "$(git rev-parse --show-toplevel)")"
  {
    printf '# Changelog\n\n'
    printf 'All notable changes to %s are documented here.  \n' "$name"
    printf 'Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).\n\n'
    printf '## [Unreleased]\n\n'
  } > CHANGELOG.md
fi

previousTag="$(git tag --list 'v[0-9]*' --sort=-v:refname | head -n1)"
changelogBefore="$(cat CHANGELOG.md)"

# A trap, not a line at the end: the entry is printed before it, and a closed
# pipe there would otherwise leave the rewritten file on disk.
if [ "$dryRun" -eq 1 ]; then
  trap 'if [ "$changelogExisted" -eq 1 ]; then printf "%s\n" "$changelogBefore" > CHANGELOG.md; else rm -f CHANGELOG.md; fi' EXIT
fi

BLOCK="$block" NEW="$new" REMOTE="$remote" PREV="$previousTag" python3 - <<'PY'
import os, re

block = os.environ['BLOCK'].strip('\n')
new, remote, prev = os.environ['NEW'], os.environ['REMOTE'], os.environ['PREV']
path = 'CHANGELOG.md'
text = open(path, encoding='utf-8').read()

if re.search(rf'^## \[{re.escape(new)}\] - ', text, re.M):
    raise SystemExit(f'{new} already in CHANGELOG.md')

lines = text.split('\n')
head = next((i for i, l in enumerate(lines) if re.match(r'^## \[Unreleased\]', l)), None)
if head is None:
    raise SystemExit('No [Unreleased] section in CHANGELOG.md')

at = head + 1
while at < len(lines) and not lines[at].startswith('## '):
    at += 1

# Releasing empties [Unreleased]: hand-written pending notes belong to the
# version that ships them. They land above the generated sections, for the
# $EDITOR pass to merge.
pending = '\n'.join(lines[head + 1:at]).strip('\n')
if pending:
    entry, _, rest = block.partition('\n')
    block = entry + '\n\n' + pending + '\n' + rest
    del lines[head + 1:at]
    at = head + 1

lines[at:at] = (block + '\n').split('\n')
text = '\n'.join(lines)

if remote:
    link = f'[Unreleased]: {remote}/compare/v{new}...HEAD'
    if re.search(r'^\[Unreleased\]:', text, re.M):
        text = re.sub(r'^\[Unreleased\]:.*$', link, text, count=1, flags=re.M)
    else:
        text = text.rstrip('\n') + '\n\n' + link + '\n'

    entry = (f'[{new}]: {remote}/compare/{prev}...v{new}' if prev
             else f'[{new}]: {remote}/releases/tag/v{new}')

    # Above the first version link, so the footer stays newest-first whether or
    # not a previous tag exists.
    anchor = re.search(r'^\[\d+\.\d+\.\d+[^\]]*\]:', text, re.M)
    if anchor:
        text = text[:anchor.start()] + entry + '\n' + text[anchor.start():]
    else:
        text = text.rstrip('\n') + '\n' + entry + '\n'

open(path, 'w', encoding='utf-8').write(text)
PY

#==============================================================================
# Review, commit, tag
#==============================================================================

printf '\n%s\n\n' "$block"

if [ "$dryRun" -eq 1 ]; then
  log "Dry run — CHANGELOG.md restored, nothing committed."
  exit 0
fi

if [ "$assumeYes" -eq 0 ]; then
  if [ -n "${EDITOR:-}" ]; then
    read -r -p "Edit the entry before committing? [y/N] " answer
    [ "${answer,,}" = "y" ] && "$EDITOR" CHANGELOG.md
  fi
  read -r -p "Release v$new? [y/N] " answer
  if [ "${answer,,}" != "y" ]; then
    if [ "$changelogExisted" -eq 1 ]; then
      printf '%s\n' "$changelogBefore" > CHANGELOG.md
    else
      rm -f CHANGELOG.md
    fi
    die "Aborted."
  fi
fi

writeVersion "$new"

git add -A
git commit -q -m "chore(release): v$new"

# Annotated tag carrying the entry, verbatim: git's default `-m` cleanup treats
# the Markdown headings as comments and strips every one of them.
newEscaped="${new//./\\.}"
git tag -a "v$new" --cleanup=verbatim \
  -m "$(sed -n "/^## \[$newEscaped\]/,/^## \[/p" CHANGELOG.md | sed '$d')"

log "Tagged v$new — push with: git -C $(pwd) push && git -C $(pwd) push origin v$new"
