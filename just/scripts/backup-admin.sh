#!/usr/bin/env bash
#
# DNF — encrypted backup of the admin keys and the project, on a USB stick.
#
#   backup-admin.sh write|check DEVICE [PASSPHRASE_FILE] [ROOT]
#
# Without it, a lost or broken admin host loses every secret of the network.
# One age file on the filesystem of DEVICE, never formatted, plus its README in
# clear. A previous backup of the same network is kept, renamed with its date.
#
# | Archive, `dnf-backup/`   | From                                       |
# |--------------------------|--------------------------------------------|
# | `nix/id_ed25519{,.pub}`  | ROOT `home/nix/.ssh/`, the deploy key      |
# | `nix/keys.txt`           | ROOT `home/nix/.config/sops/age/`, admin   |
# | `infra.key`              | ROOT `etc/sops/age/infra.key`              |
# | `project.bundle`         | the project, every branch (`git bundle`)   |
#
# Run as root via `just backup-admin`, WORKDIR set to the project, ROOT the
# system holding the keys (`/`, or `/mnt` from the installer). Without
# PASSPHRASE_FILE, age asks for one. `check` reads the file back and compares
# it with the keys and the project.

set -euo pipefail

# Same rendering as the `_log` / `_warn` / `_err` recipes of
# just/common/_helpers.just.
log() { printf '[ \033[1;36mDNF\033[0m ] \033[1;35m%s\033[0m • %s\n' "$1" "$2"; }
warn() { printf '[ \033[1;36mDNF\033[0m ] \033[1;33mWRN\033[0m • %s\n' "$*" >&2; }
die() {
  printf '[ \033[1;36mDNF\033[0m ] \033[1;31mERR\033[0m • %s\n' "$*" >&2
  exit 1
}

[ $# -ge 2 ] || die "usage: backup-admin.sh write|check DEVICE [PASSPHRASE_FILE] [ROOT]"
action="$1"
device="$2"
passFile="${3:-}"
root="${4:-/}"
case "$action" in
write | check) ;;
*) die "unknown action '$action': write or check." ;;
esac
[ "$(id -u)" = 0 ] || die "run as root (just backup-admin)."
workDir="${WORKDIR:?WORKDIR: the project directory}"
[ -b "$device" ] || die "$device is not a block device: plug the USB stick in."
[ -z "$passFile" ] || [ -s "$passFile" ] || die "passphrase file $passFile is missing or empty."
for bin in age git mount tar yq; do
  command -v "$bin" >/dev/null || die "$bin not found in PATH."
done

sshKey="$root/home/nix/.ssh/id_ed25519"
adminKey="$root/home/nix/.config/sops/age/keys.txt"
infraKey="$root/etc/sops/age/infra.key"
for f in "$sshKey" "$sshKey.pub" "$adminKey" "$infraKey"; do
  [ -s "$f" ] || die "$f is missing: no admin keys under $root."
done
domain="$(yq -r '.network.domain' "$workDir/etc/config.yaml")"
name="dnf-backup-$domain"

work="$(mktemp -d)"
mnt="$work/mnt"
mkdir "$mnt"
cleanup() {
  if mountpoint -q "$mnt"; then umount "$mnt"; fi
  rm -rf "$work"
}
trap cleanup EXIT

# The batchpass plugin of age reads the passphrase from a descriptor, trailing
# newlines stripped as by disko; a plain age asks on the terminal.
encrypt() {
  if [ -n "$passFile" ]; then
    AGE_PASSPHRASE_FD=3 age -e -j batchpass -o "$1" 3<"$passFile"
  else
    age -p -o "$1"
  fi
}
decrypt() {
  if [ -n "$passFile" ]; then
    AGE_PASSPHRASE_FD=3 age -d -j batchpass "$1" 3<"$passFile"
  else
    age -d "$1"
  fi
}

# Root reads a project owned by its admin: git refuses it otherwise.
git=(git -c safe.directory="$workDir" -C "$workDir")

#------------------------------------------------------------------------------
# Write
#------------------------------------------------------------------------------

if [ "$action" = write ]; then
  [ -z "$("${git[@]}" status --porcelain)" ] ||
    warn "uncommitted changes in $workDir are not in the backup: commit, then back up again."
  staging="$work/dnf-backup"
  mkdir -m 700 "$staging" "$staging/nix"
  cp "$sshKey" "$sshKey.pub" "$adminKey" "$staging/nix/"
  cp "$infraKey" "$staging/infra.key"
  "${git[@]}" bundle create -q "$staging/project.bundle" --all
  cat >"$staging/README.txt" <<EOF
DNF backup of the network $domain, $(date +%F).

$name.tar.age is encrypted with age, by the passphrase typed at the
install: the disk passphrase of the admin host when its disk is encrypted.

Inside:
- nix/: the deploy key of the nix account (SSH), and the admin age key
  derived from it: they open every host and usr/secrets/secrets.yaml;
- infra.key: the infra age key, /etc/sops/age/infra.key;
- project.bundle: the project, /etc/nixos, as a git bundle.

Open it on any Linux with age:

  age -d $name.tar.age | tar -x
  git clone dnf-backup/project.bundle nixos

Restore an admin host:
https://darkone-linux.github.io/en/doc/admin-guide/install/first-network-installation/
EOF

  mount "$device" "$mnt"

  # Renamed once complete: a failed or interrupted write leaves the previous
  # backup in place, and no half file under the final name.
  part="$mnt/$name.tar.age.part"
  tar -C "$work" -cf - dnf-backup | encrypt "$part" || {
    rm -f "$part"
    die "$name.tar.age not written on $device."
  }
  if [ -e "$mnt/$name.tar.age" ]; then
    old="$name.$(date -r "$mnt/$name.tar.age" +%Y%m%d-%H%M%S)"
    mv "$mnt/$name.tar.age" "$mnt/$old.tar.age"
    [ ! -e "$mnt/$name.README.txt" ] || mv "$mnt/$name.README.txt" "$mnt/$old.README.txt"
    log BACKUP "Previous backup kept as $old.tar.age."
  fi
  mv "$part" "$mnt/$name.tar.age"
  cp "$staging/README.txt" "$mnt/$name.README.txt"
  sync
  umount "$mnt"
  log BACKUP "$name.tar.age written on $device."
  exit 0
fi

#------------------------------------------------------------------------------
# Check
#------------------------------------------------------------------------------

# Read-write, never written: a read-only mount fails next to the desktop's own
# (udisks) of the same stick.
mount "$device" "$mnt"
[ -s "$mnt/$name.tar.age" ] || die "no $name.tar.age on $device."
[ -s "$mnt/$name.README.txt" ] || die "no $name.README.txt on $device."
out="$work/out"
mkdir -m 700 "$out"
decrypt "$mnt/$name.tar.age" | tar -C "$out" -xf - ||
  die "$name.tar.age does not open: wrong passphrase, or a damaged stick."
cmp -s "$out/dnf-backup/nix/id_ed25519" "$sshKey" || die "the deploy key of the backup differs from $sshKey."
cmp -s "$out/dnf-backup/nix/keys.txt" "$adminKey" || die "the admin age key of the backup differs from $adminKey."
cmp -s "$out/dnf-backup/infra.key" "$infraKey" || die "the infra key of the backup differs from $infraKey."
head="$("${git[@]}" rev-parse HEAD)"

# `grep -q` would stop reading early: SIGPIPE on git, a false failure under
# pipefail.
git bundle list-heads "$out/dnf-backup/project.bundle" | grep "^$head " >/dev/null ||
  die "the project of the backup misses its last commit, $head."
log BACKUP "$name.tar.age on $device checked: keys and project match."
