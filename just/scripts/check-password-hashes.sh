#!/usr/bin/env bash
#
# List host users without a password hash in the shared sops file.
#
# Each user of a non-isolated host needs `user/<login>/password-hash`
# (`modules/system/sops.nix`). A missing one only shows at build time: an
# opaque `manifest-for-users.json` failure naming a single login.
#
# - YAML keys only: values stay encrypted, nothing is decrypted;
# - isolation from the framework defaults (`ai-space` profile, microVM guest):
#   an explicit `darkone.system.sops.isolated` in a host configuration is not
#   seen;
# - one line per missing login: its hosts and the fix. Exit 0 even then:
#   `just generate` warns, a fleet update still builds the other hosts.

set -euo pipefail

workDir="${WORKDIR:-$PWD}"
hosts="$workDir/var/generated/hosts.nix"
secrets="$workDir/usr/secrets/secrets.yaml"

# Fresh project, before the first `just generate` or `configure-admin-host`.
[ -f "$hosts" ] && [ -f "$secrets" ] || exit 0
for bin in jq nix-instantiate yq; do
  command -v "$bin" >/dev/null || {
    echo "$bin not found, password hashes not checked." >&2
    exit 0
  }
done

# `<login> <host>` for every user of a host holding fleet secrets.
expected="$(nix-instantiate --eval --strict --json "$hosts" | jq -r '
  .[]
  | select(.profile != "ai-space" and (.features // {})["microvm-guest"] == null)
  | .hostname as $host
  | (.users // [])[]
  | "\(.) \($host)"')"

# Logins holding a `user.<login>.password-hash` key.
present="$(yq -r '(.user // {}) | to_entries | .[] | select(.value["password-hash"] != null) | .key' "$secrets")"

# `has` lines first: awk knows every hash before it meets the first host user.
{
  awk '{ print "has", $0 }' <<< "$present"
  awk '{ print "need", $0 }' <<< "$expected"
} | awk '
  $1 == "has" { has[$2] = 1; next }
  $1 == "need" && $2 != "" && !($2 in has) {
    if (!($2 in on)) order[++count] = $2
    on[$2] = ($2 in on) ? on[$2] ", " $3 : $3
  }
  END {
    for (i = 1; i <= count; i++)
      printf "%s (%s): just passwd %s\n", order[i], on[order[i]], order[i]
  }'
