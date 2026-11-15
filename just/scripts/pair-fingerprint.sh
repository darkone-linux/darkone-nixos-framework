# DNF — FFFF half of the pairing code: 4 digits from an ed25519 host key.
#
#   pair-fingerprint.sh [FILE]    # FILE, or stdin
#
# Input: `ssh-ed25519 AAAA… [comment]` (`/etc/ssh/ssh_host_ed25519_key.pub`)
# or `ssh-keyscan` output (`host ssh-ed25519 AAAA…`); `#` lines and other key
# types are skipped. Derivation:
#
# - SHA-256 of the decoded key blob, the hash `ssh-keygen -l` shows as `SHA256:`;
# - its first 8 hex digits as an integer, mod 10000, on 4 digits.
#
# One implementation for both sides: the installer ISO embeds it (`dnf-pair`),
# the admin host runs it on `ssh-keyscan` (`just _pair`). Exit 1 without
# exactly one distinct ed25519 key. Needs coreutils only.
#
# shellcheck shell=bash # embedded by `writeShellApplication`: no shebang

set -euo pipefail

# Blob of an ed25519 key: `ssh-ed25519` (11 bytes) + 32 bytes, base64 of a
# fixed prefix then 43 characters. Anything else is no key of this type.
blobRe='^AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43}$'

key=""
fields=()

# `|| …`: a last line without a newline still counts.
while read -r -a fields || [ "${#fields[@]}" -gt 0 ]; do
  if [ "${#fields[@]}" -eq 0 ] || [[ ${fields[0]} == "#"* ]]; then
    continue
  fi
  for i in "${!fields[@]}"; do
    if [ "${fields[i]}" != ssh-ed25519 ]; then
      continue
    fi
    blob="${fields[i + 1]:-}"
    if [[ ! $blob =~ $blobRe ]]; then
      echo "pair-fingerprint: malformed ssh-ed25519 key" >&2
      exit 1
    fi

    # A host reached on several addresses is scanned once per address.
    if [ -n "$key" ] && [ "$key" != "$blob" ]; then
      echo "pair-fingerprint: several ssh-ed25519 keys, expected one" >&2
      exit 1
    fi
    key="$blob"
    break
  done
done < "${1:-/dev/stdin}"

if [ -z "$key" ]; then
  echo "pair-fingerprint: no ssh-ed25519 key" >&2
  exit 1
fi

hex="$(printf '%s' "$key" | base64 -d | sha256sum)"
printf '%04d\n' "$((16#${hex:0:8} % 10000))"
