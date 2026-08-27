#!/usr/bin/env bash
#
# DNF — idempotent generation of the fleet's internal sops secrets.
#
# Run via `just configure-admin-host` (and `just install`), which sets WORKDIR
# and SOPS_AGE_KEY_FILE and fixes the filesystem permissions afterwards.
#
# Nothing is hard-coded here: `<workDir>#secretsPlan` (flake output, see
# dnf/lib/mk-configuration.nix) collects every `sops.secrets` entry declared by
# every host and classifies it through `dnfLib.mkSecretPlan`. This script only
# knows how to *produce* a value for a generator id, and never overwrites an
# existing entry — rotating a secret stays a deliberate, manual act.
#
# The encrypted file is rewritten ONLY when at least one secret was created:
# re-encrypting refreshes the sops MAC and would leave a spurious git diff
# behind on every run.
#
# Contract:
#  - stderr: one `- new secret: <id>` line per created entry, plus warnings;
#  - stdout: the number of created entries, or `skip` when the fleet cannot be
#    evaluated yet (fresh project, `just generate` not run).

set -euo pipefail
umask 077

workDir="${WORKDIR:-$PWD}"
secrets="$workDir/usr/secrets/secrets.yaml"

# Same rendering as the `_warn` / `_err` recipes of assets/just/common.just.
warn() { printf '[ \033[1;36mDNF\033[0m ] \033[1;33mWRN\033[0m • %s\n' "$*" >&2; }
die() {
  printf '[ \033[1;36mDNF\033[0m ] \033[1;31mERR\033[0m • %s\n' "$*" >&2
  exit 1
}

# Progress goes to stderr: stdout carries the machine-readable result the
# calling recipe turns into its step line.
new() { printf -- '- new secret: %s\n' "$1" >&2; }

for bin in jq nix openssl sops yq; do
  command -v "$bin" >/dev/null 2>&1 || die "missing dependency: $bin (enter 'nix develop')."
done
[ -f "$secrets" ] || die "secrets file not found ($secrets)."

# sops resolves `.sops.yaml` — the recipients it re-encrypts for — by walking up
# from the CURRENT directory, not from the file it is handed. Every other path
# used below is absolute.
cd "$(dirname "$secrets")"

# The plan is derived from the generated inventory the flake reads. On a brand
# new project `just generate` has not run yet: there is simply no fleet to
# collect secrets from.
if [ ! -f "$workDir/var/generated/hosts.nix" ]; then
  warn "No fleet generated yet — internal secrets skipped (run 'just generate')."
  echo skip
  exit 0
fi

work="$(mktemp -d)"
plain="$work/secrets.yaml"

# `wipe` ships in the DNF dev shell; a plain rm is the fallback (on a tmpfs
# /tmp there is nothing left to overwrite anyway).
cleanup() {
  if command -v wipe >/dev/null 2>&1; then
    wipe -rf "$work" >/dev/null 2>&1 || rm -rf "$work"
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

if ! nix --extra-experimental-features 'nix-command flakes' eval --json \
  "$workDir#secretsPlan" >"$work/plan.json" 2>"$work/plan.err"; then
  warn "Fleet not evaluable — internal secrets skipped:"
  cat "$work/plan.err" >&2
  echo skip
  exit 0
fi

sops -d "$secrets" >"$plain" || die "cannot decrypt $secrets (missing or wrong age key?)."

#------------------------------------------------------------------------------
# YAML access
#------------------------------------------------------------------------------

# A sops `key` addresses a nested YAML path with slashes
# (`restic/gw-ag/rest-password`); yq wants `."restic"."gw-ag"."rest-password"`.
yqPath() {
  local part path=""
  local IFS=/
  for part in $1; do path="$path.\"$part\""; done
  printf '%s' "$path"
}

# Present means "holds a non-empty value": a key left at null by a hand edit is
# as good as absent, and sops-nix would fail on it at activation time.
hasSecret() {
  local value
  value="$(yq -r "$(yqPath "$1") // \"\"" "$plain" 2>/dev/null)" || return 1
  [ -n "$value" ]
}

putSecret() {
  DNF_SECRET_VALUE="$2" yq --inplace "$(yqPath "$1") = strenv(DNF_SECRET_VALUE)" "$plain"
}

#------------------------------------------------------------------------------
# Generators
#------------------------------------------------------------------------------
#
# One case per generator id declared in dnf/lib/secrets.nix. Bundle generators
# (several entries born together) are handled by `generateUnit` below.

singleValue() {
  case "$1" in
  hex16) openssl rand -hex 16 ;;
  hex32) openssl rand -hex 32 ;;
  b64) openssl rand -base64 24 ;;

  # oauth2-proxy decodes the cookie key before checking its length, and its
  # base64 decoder is the URL-safe one.
  b64url32) openssl rand -base64 32 | tr -- '+/' '-_' ;;

  # Garage access-key format: `GK` followed by 24 hex characters.
  s3-key-id) printf 'GK%s' "$(openssl rand -hex 12)" ;;
  rsa4096) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 2>/dev/null ;;

  # `die` would only kill the command substitution the caller runs us in, so
  # the caller checks the exit status instead.
  *) return 1 ;;
  esac
}

# Self-signed pair for Kanidm's internal HTTPS listener, as documented in
# modules/service/idm.nix. Both PEM blocks come back on stdout — key first,
# certificate second — so the private key never lands on a filesystem.
generateX509Pair() {
  local pair
  pair="$(openssl req -x509 -newkey rsa:2048 -keyout /dev/stdout -out /dev/stdout \
    -days 3650 -nodes -subj "/CN=127.0.0.1" 2>/dev/null)"
  x509Key="${pair%%-----BEGIN CERTIFICATE-----*}"
  x509Chain="-----BEGIN CERTIFICATE-----${pair#*-----BEGIN CERTIFICATE-----}"
}

# Create every key of one generation unit. Callers guarantee they are all
# missing.
generateUnit() {
  local gen="$1" key
  shift
  if [ "$gen" = "x509" ]; then
    generateX509Pair
    for key in "$@"; do
      case "$key" in
      *-key) putSecret "$key" "$x509Key" ;;
      *) putSecret "$key" "$x509Chain" ;;
      esac
      new "$key"
    done
  else
    local value
    for key in "$@"; do
      value="$(singleValue "$gen")" \
        || die "unknown generator '$gen' (declared in dnf/lib/secrets.nix, unimplemented here)."
      putSecret "$key" "$value"
      new "$key"
    done
  fi
}

#------------------------------------------------------------------------------
# Convergence
#------------------------------------------------------------------------------

created=0
while IFS=$'\t' read -r gen unitKeys; do
  [ -n "$gen" ] || continue
  missing=()
  present=0
  for key in $unitKeys; do
    if hasSecret "$key"; then present=$((present + 1)); else missing+=("$key"); fi
  done
  [ "${#missing[@]}" -gt 0 ] || continue

  # A half-present bundle means someone replaced one member by hand: a fresh
  # certificate would no longer match the stored key. Report, never guess.
  if [ "$present" -gt 0 ]; then
    warn "Incomplete '$gen' secret group, missing ${missing[*]} — fix it with 'just sops'."
    continue
  fi
  generateUnit "$gen" "${missing[@]}"
  created=$((created + ${#missing[@]}))
done < <(jq -r '.generate[] | [.gen, (.keys | join(" "))] | @tsv' "$work/plan.json")

if [ "$created" -gt 0 ]; then
  cp "$plain" "$secrets"
  sops -e -i "$secrets"
fi

#------------------------------------------------------------------------------
# What DNF cannot generate
#------------------------------------------------------------------------------

# Reported only while actually missing, so a converged fleet stays silent.
report() {
  local key pending=()
  for key in $(jq -r ".$1[]" "$work/plan.json"); do
    hasSecret "$key" || pending+=("$key")
  done
  [ "${#pending[@]}" -gt 0 ] && warn "$2 ${pending[*]}"
  return 0
}

report manual "Missing secret(s) DNF must not invent, set them with 'just sops':"
report unknown "Secret(s) unknown to the registry (dnf/lib/secrets.nix):"

echo "$created"
