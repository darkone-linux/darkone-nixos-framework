#!/usr/bin/env bash
#
# DNF — keys and sops skeleton of an admin host, without its `nix` account.
#
#   bootstrap-keys.sh [--root DIR] [--password-hash LOGIN HASH]...
#                     [--luks HOST PASSPHRASE_FILE]
#
# The first machine of a network is its admin host, and the deploy account only
# exists once DNF runs there. So root writes everything, under DIR (`/` on the
# machine itself, `/mnt` from the installer), with the ids NixOS will give it.
#
# Run via `just bootstrap-keys` and `just configure-admin-host`, WORKDIR set to
# the project. Creates what is missing, never overwrites:
#
# | Under DIR                            | Project, `usr/secrets/`        |
# |--------------------------------------|--------------------------------|
# | `home/nix/.ssh/id_ed25519`           | `nix.pub`, `.gitignore`        |
# | `home/nix/.config/sops/age/keys.txt` | `.sops.yaml`                   |
# | `etc/sops/age/infra.key`             | `secrets.yaml`, `harmonia.pub` |
#
# `secrets.yaml` holds what the first boot needs: a password hash for every
# account of the host, or sops-nix installs none of them. `nix` gets a random,
# forgotten password: it only ever logs in with its key. `--password-hash`
# takes a ready crypt hash (`mkpasswd`) for any other account.
#
# `--luks`: offline half of `just luks HOST pre` for a disk just formatted with
# PASSPHRASE_FILE, which becomes the shared `luks-passphrase`; the initrd SSH
# host key is also staged under DIR (dnf/modules/system/luks.nix).

set -euo pipefail

# Same rendering as the `_log` / `_info` / `_warn` / `_err` recipes of
# just/common/_helpers.just.
log() { printf '[ \033[1;36mDNF\033[0m ] \033[1;35m%s\033[0m • %s\n' "$1" "$2"; }
info() { printf '[ \033[1;36mDNF\033[0m ] \033[1;32m%s\033[0m • %s\n' "$1" "$2" >&2; }
warn() { printf '[ \033[1;36mDNF\033[0m ] \033[1;33mWRN\033[0m • %s\n' "$*" >&2; }
die() {
  printf '[ \033[1;36mDNF\033[0m ] \033[1;31mERR\033[0m • %s\n' "$*" >&2
  exit 1
}

root=/
hashes=()
luksHost=""
luksFile=""

# Crypt alphabet only (yescrypt, sha-512, bcrypt): the hash travels inside
# single-quoted shell words of the recipes.
hashRe='^\$[0-9a-z]+\$[./0-9A-Za-z$=,+-]+$'
while [ $# -gt 0 ]; do
  case "$1" in
  --root)
    [ $# -ge 2 ] || die "--root needs a directory."
    root="$2"
    shift 2
    ;;
  --password-hash)
    [ $# -ge 3 ] || die "--password-hash needs a login and a hash."
    [[ $2 =~ ^[a-zA-Z][a-zA-Z0-9_-]{1,59}$ ]] || die "invalid login '$2'."
    [[ $3 =~ $hashRe ]] || die "not a crypt hash for $2: expected the output of 'mkpasswd'."
    hashes+=("$2" "$3")
    shift 3
    ;;
  --luks)
    [ $# -ge 3 ] || die "--luks needs a host and a passphrase file."
    [[ $2 =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || die "invalid host '$2'."
    [ -s "$3" ] || die "empty or missing LUKS passphrase file '$3'."
    luksHost="$2"
    luksFile="$3"
    shift 3
    ;;
  *) die "unknown argument '$1'." ;;
  esac
done

workDir="${WORKDIR:-$PWD}"
[ "$(id -u)" = 0 ] || die "run as root: the keys belong to an account that may not exist yet."
[ -d "$root" ] || die "target root $root not found."
[ -f "$workDir/etc/config.yaml" ] || die "$workDir is not a DNF project (no etc/config.yaml)."
for bin in age-keygen mkpasswd nix-store openssl sops ssh-keygen ssh-to-age yq; do
  command -v "$bin" >/dev/null 2>&1 || die "missing dependency: $bin (enter 'nix develop')."
done

# `nix` as NixOS creates it: uid set by dnf-generator (`NIX_USER_UID`), group
# `users` of every normal account.
nixIds=65000:100
nixHome="${root%/}/home/nix"
sshKey="$nixHome/.ssh/id_ed25519"
adminKey="$nixHome/.config/sops/age/keys.txt"
infraDir="${root%/}/etc/sops/age"
infraKey="$infraDir/infra.key"

# Project files keep the owner of the project, as `_fix_fs_permissions` does.
owner="$(stat -c %u:%g "$workDir")"
secretsDir="$workDir/usr/secrets"
secrets="$secretsDir/secrets.yaml"

# Missing directories only: NixOS fixes the home itself at activation, and
# never touches what lies below.
newDir() {
  [ -d "$1" ] && return 0
  mkdir -p "$(dirname "$1")"
  install -d -m "$2" -o "${3%:*}" -g "${3#*:}" "$1"
}

#------------------------------------------------------------------------------
# Restore, never re-key
#------------------------------------------------------------------------------

# A project that already has secrets was sealed for keys living on its former
# admin host: fresh keys would decrypt nothing and be refused by every host.
for f in nix.pub .sops.yaml; do
  [ -f "$sshKey" ] || [ ! -f "$secretsDir/$f" ] ||
    die "usr/secrets/$f exists but not $sshKey: restore the deploy key of the former admin host."
done
for f in .sops.yaml secrets.yaml; do
  [ -f "$infraKey" ] || [ ! -f "$secretsDir/$f" ] ||
    die "usr/secrets/$f exists but not $infraKey: restore the infra key of the former admin host."
done

#------------------------------------------------------------------------------
# Keys under the target root
#------------------------------------------------------------------------------

if [ -f "$sshKey" ]; then
  info SSH "Deploy key already exists."
else
  log SSH "Creating the nix deploy key..."
  newDir "$nixHome" 700 "$nixIds"
  newDir "$nixHome/.ssh" 700 "$nixIds"
  ssh-keygen -q -t ed25519 -N "" -C "nix@$(uname -n)" -f "$sshKey"
  chown "$nixIds" "$sshKey" "$sshKey.pub"
fi
if [ ! -f "$sshKey.pub" ]; then
  log SSH "Restoring the public half of the deploy key..."
  ssh-keygen -y -f "$sshKey" >"$sshKey.pub"
  chown "$nixIds" "$sshKey.pub"
fi

if [ -s "$adminKey" ]; then
  info SOPS "Admin key file already exists."
else
  log SOPS "Admin key file creation from the deploy key..."
  for d in .config .config/sops .config/sops/age; do newDir "$nixHome/$d" 700 "$nixIds"; done
  ssh-to-age -private-key -i "$sshKey" -o "$adminKey"
  chmod 600 "$adminKey"
  chown "$nixIds" "$adminKey"
fi

# Owned by `nix` on the admin host only, so its tooling reads the key; sops-nix
# reads it as root. `push-key` gives it to root everywhere else.
if [ -f "$infraKey" ]; then
  info SOPS "Infra key file already exists."
else
  log SOPS "Infra private key file generation..."
  newDir "$infraDir" 755 0:0
  chown "${nixIds%:*}" "$infraDir"
  age-keygen -o "$infraKey" 2>/dev/null
  chmod 600 "$infraKey"
  chown "$nixIds" "$infraKey"
fi

#------------------------------------------------------------------------------
# Public files of the project
#------------------------------------------------------------------------------

newDir "$workDir/usr" 755 "$owner"
newDir "$secretsDir" 755 "$owner"

# Only private keys are kept away from git; the encrypted secrets are committed.
if [ ! -f "$secretsDir/.gitignore" ]; then
  echo '*.key' >"$secretsDir/.gitignore"
  chown "$owner" "$secretsDir/.gitignore"
fi

if [ -f "$secretsDir/nix.pub" ]; then
  info SSH "Public key usr/secrets/nix.pub already exists."
  cmp -s <(cut -d' ' -f1,2 "$secretsDir/nix.pub") <(cut -d' ' -f1,2 "$sshKey.pub") ||
    warn "usr/secrets/nix.pub is not the public half of $sshKey: hosts will refuse this deploy key."
else
  install -m 644 -o "${owner%:*}" -g "${owner#*:}" "$sshKey.pub" "$secretsDir/nix.pub"
fi

# Same rules as `_regen-sops-yaml`, which rewrites the file during a rotation.
if [ -f "$secretsDir/.sops.yaml" ]; then
  info SOPS ".sops.yaml file already exists."
else
  log SOPS ".sops.yaml file generation..."
  {
    printf '%s\n' 'creation_rules:' '  - path_regex: "[^/]+\\.yaml$"' '    key_groups:' '    - age:'
    printf '      - %s\n' "$(ssh-to-age -i "$sshKey.pub")" "$(age-keygen -y "$infraKey")"
  } >"$secretsDir/.sops.yaml"
  chown "$owner" "$secretsDir/.sops.yaml"
fi

#------------------------------------------------------------------------------
# secrets.yaml
#------------------------------------------------------------------------------

# Clear values live in /run (tmpfs), never on a disk, unless TMPDIR says
# otherwise. `wipe` ships in the DNF dev shell; a plain rm is the fallback.
work="$(mktemp -d -p "${TMPDIR:-/run}" dnf-bootstrap-XXXXXX)"
cleanup() { wipe -rf "$work" >/dev/null 2>&1 || rm -rf "$work"; }
trap cleanup EXIT
plain="$work/secrets.yaml"
if [ -f "$secrets" ]; then
  SOPS_AGE_KEY_FILE="$infraKey" sops -d "$secrets" >"$plain" ||
    die "cannot decrypt usr/secrets/secrets.yaml with $infraKey."
else
  echo '{}' >"$plain"
fi

# A sops key `user/nix/password-hash` is the YAML path `."user"."nix"."password-hash"`.
yqPath() {
  local part path=""
  local IFS=/
  for part in $1; do path="$path.\"$part\""; done
  printf '%s' "$path"
}
hasSecret() { [ -n "$(yq -r "$(yqPath "$1") // \"\"" "$plain")" ]; }
putSecret() { DNF_SECRET_VALUE="$2" yq --inplace "$(yqPath "$1") = strenv(DNF_SECRET_VALUE)" "$plain"; }
changed=0

# Through stdin: a password in argv is readable by every local user.
if ! hasSecret user/nix/password-hash; then
  log SOPS "Random password hash for the nix account..."
  putSecret user/nix/password-hash "$(openssl rand -base64 32 | mkpasswd -s -m sha-512)"
  changed=1
fi

set -- "${hashes[@]}"
while [ $# -gt 0 ]; do
  if hasSecret "user/$1/password-hash"; then
    info SOPS "Password of $1 already set, kept (change it with 'just passwd $1')."
  else
    log SOPS "Password hash of $1..."
    putSecret "user/$1/password-hash" "$2"
    changed=1
  fi
  shift 2
done

# Binary-cache signing pair: the public half is committed and read by
# nix-cache to trust harmonia-signed paths, the private half goes to sops.
if [ -f "$secretsDir/harmonia.pub" ]; then
  info SOPS "Harmonia public key already exists."
else
  log SOPS "Generating Harmonia binary-cache signing key..."
  domain="$(yq '.network.domain // "harmonia"' "$workDir/etc/config.yaml" 2>/dev/null || echo harmonia)"
  nix-store --generate-binary-cache-key "cache.$domain-1" "$work/harmonia.key" "$work/harmonia.pub"
  putSecret harmonia-secret-key "$(cat "$work/harmonia.key")"
  install -m 644 -o "${owner%:*}" -g "${owner#*:}" "$work/harmonia.pub" "$secretsDir/harmonia.pub"
  changed=1
fi

#------------------------------------------------------------------------------
# LUKS: secrets, public manifest, initrd host key
#------------------------------------------------------------------------------

if [ -n "$luksHost" ]; then

  # `$(cat)` drops trailing newlines, as disko does with its `passwordFile`:
  # the stored value is the keyslot, byte for byte.
  passphrase="$(cat "$luksFile")"
  if ! hasSecret luks-passphrase; then
    log LUKS "Shared LUKS passphrase..."
    putSecret luks-passphrase "$passphrase"
    changed=1
  elif [ "$(yq -r '."luks-passphrase"' "$plain")" != "$passphrase" ]; then
    die "luks-passphrase in sops is not the passphrase of $luksFile: the disk would not open with it."
  fi

  # Random, as `just luks` makes it: `just luks $luksHost passwd` sets one.
  if ! hasSecret "luks/$luksHost/passphrase"; then
    log LUKS "Random per-host passphrase of $luksHost..."
    putSecret "luks/$luksHost/passphrase" "$(openssl rand -base64 32)"
    changed=1
  fi
  if ! hasSecret "luks/$luksHost/initrd-key"; then
    log LUKS "Initrd SSH host key of $luksHost..."
    ssh-keygen -q -t ed25519 -N "" -C "" -f "$work/initrd-key"
    putSecret "luks/$luksHost/initrd-key" "$(base64 -w0 <"$work/initrd-key")"
    putSecret "luks/$luksHost/initrd-key-pub" "$(ssh-keygen -y -f "$work/initrd-key")"
    changed=1
  fi

  # The bootloader embeds the key at install: on the disk before `nixos-install`,
  # or the first boot has no initrd sshd.
  initrdDir="${root%/}/var/lib/luks-initrd"
  initrdKey="$initrdDir/ssh_host_ed25519_key"
  if [ -f "$initrdKey" ]; then
    [ "$(ssh-keygen -y -f "$initrdKey")" = "$(yq -r ".\"luks\".\"$luksHost\".\"initrd-key-pub\"" "$plain")" ] ||
      warn "$initrdKey is not the initrd key of sops: 'just luks $luksHost' adopts it once the host is up."
  else
    log LUKS "Initrd SSH host key staged under $initrdDir..."
    newDir "$initrdDir" 700 0:0
    (umask 077 && yq -r ".\"luks\".\"$luksHost\".\"initrd-key\"" "$plain" | base64 -d >"$initrdKey")
    ssh-keygen -y -f "$initrdKey" >"$initrdKey.pub"
    chmod 644 "$initrdKey.pub"
  fi

  # Public manifest: the module wakes up for a host listed there.
  manifest="$secretsDir/luks.json"
  if [ ! -f "$manifest" ]; then
    echo '{}' >"$manifest"
    chown "$owner" "$manifest"
  fi
  if ! yq -e ".\"$luksHost\"" "$manifest" >/dev/null 2>&1; then
    yq -i -p=json -o=json ".\"$luksHost\" = {}" "$manifest"
    chown "$owner" "$manifest"
    log LUKS "$luksHost declared in usr/secrets/luks.json."
  fi
fi

# Re-encrypting refreshes the sops MAC: only when an entry was added, or every
# run would leave a git diff behind. sops finds `.sops.yaml` from its CWD.
if [ "$changed" = 1 ]; then
  (cd "$secretsDir" && sops -e "$plain") >"$work/secrets.enc"
  install -m 644 -o "${owner%:*}" -g "${owner#*:}" "$work/secrets.enc" "$secrets"
  log SOPS "usr/secrets/secrets.yaml updated."
fi
