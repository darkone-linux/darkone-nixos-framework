#!/usr/bin/env bash
#
# Commit message gate, shared by the `commit-msg` hook and CI (rules: AGENTS.md):
#
# - exactly one line: `<type>(<scope>): <subject>`, `!` after the scope for a
#   breaking change;
# - type from the closed list git-cliff groups on (`just/scripts/cliff.toml`);
# - 80 characters max.
#
# Usage:
#
#   check-commit-msg.sh <file>                 hook: raw commit editor buffer
#   check-commit-msg.sh --commits <rev-list>   CI: every non-merge commit
#
# Hook install: ln -s ../../scripts/check-commit-msg.sh .git/hooks/commit-msg

set -euo pipefail

# Characters, not bytes: `—` or `→` count as one.
export LC_ALL=C.UTF-8

types='feat|fix|perf|refactor|docs|test|build|ci|chore|security|revert'
pattern="^($types)\([a-z0-9._,/-]+\)!?: [^[:space:]]"
max=80

# Why a message is refused; no output means valid.
violation() {
  local message=$1
  local subject=${message%%$'\n'*}

  if [ -z "$message" ]; then
    echo "empty message"
  elif [ "$message" != "$subject" ]; then
    echo "more than one line"
  elif ! [[ $subject =~ $pattern ]]; then
    echo "expected <type>(<scope>): <subject>, type in [$types]"
  elif [ "${#subject}" -gt "$max" ]; then
    echo "subject over $max chars (${#subject})"
  fi
}

# Hook mode. Git runs the hook before its own cleanup: drop the `commit -v`
# diff below the scissors, comment lines, trailing spaces and blank edges.
check_file() {
  local cc message reason

  cc=$(git config --get core.commentChar || true)
  case "$cc" in "" | auto) cc='#' ;; esac

  message=$(sed -e "/^${cc} -\{8,\} >8 -\{8,\}\$/,\$d" -e "/^${cc}/d" \
    -e 's/[[:space:]]*$//' "$1" | sed -e '/./,$!d')
  reason=$(violation "$message")
  if [ -n "$reason" ]; then
    echo "commit-msg: refused, $reason:" >&2
    printf '%s\n' "$message" | sed 's/^/  | /' >&2
    return 1
  fi
}

# CI mode. Merges skipped: PR merge refs and the merge button write git's own
# subject, never a conventional one.
check_commits() {
  local shas sha reason count=0 status=0 prefix=""

  # Outside a process substitution: a bad range must fail, not check nothing.
  shas=$(git rev-list --no-merges "$@")

  # GitHub turns `::error::` lines into run annotations.
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    prefix="::error::"
  fi

  for sha in $shas; do
    count=$((count + 1))
    reason=$(violation "$(git log -1 --format=%B "$sha")")
    if [ -n "$reason" ]; then
      echo "${prefix}${sha:0:7} ${reason}: $(git log -1 --format=%s "$sha")"
      status=1
    fi
  done
  echo "$count commit(s) checked."
  return "$status"
}

case "${1:-}" in
--commits)
  shift
  check_commits "$@"
  ;;
"" | -h | --help)
  echo "usage: $0 <message-file> | --commits <rev-list args>" >&2
  exit 2
  ;;
*)
  check_file "$1"
  ;;
esac
