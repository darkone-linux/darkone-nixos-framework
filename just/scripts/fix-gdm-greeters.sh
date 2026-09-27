#!/usr/bin/env bash
#
# Realign the `gdm-greeter*` accounts on the UIDs nixpkgs now declares.
#
# nixpkgs' gdm.nix renumbered its greeters (60578 + i); update-users-groups
# never renumbers an existing user, so hosts installed before keep the old
# UIDs, warn on every activation and may hold two greeters on one UID.
#
# Run via `just fix-gdm-greeters <host>[,<host>...] [check|apply]`, which pipes
# this file to `sudo bash -s` on each node. `check` (default) writes nothing.
#
# `apply`, only on the shifted greeters:
#  - stops GDM (refused while a graphical user session is open, `FORCE=1`
#    overrides: that session is killed);
#  - drops them from /etc/passwd and /etc/shadow, backup kept in
#    /var/lib/nixos/backup-gdm-greeters-<date>/;
#  - re-runs the users activation snippet: accounts recreated on the declared
#    UIDs, their files chowned over, GDM restarted.
#
# Idempotent: an aligned host reports OK and changes nothing.

set -uo pipefail

MODE="${MODE:-check}"
FORCE="${FORCE:-0}"
ACTIVATE=/run/current-system/activate
BACKUP_DIR="/var/lib/nixos/backup-gdm-greeters-$(date +%Y%m%dT%H%M%S)"

#------------------------------------------------------------------------------
# Output
#------------------------------------------------------------------------------

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""; }

HOST="${HOSTNAME:-$(uname -n)}"

info() { echo "  $*"; }
act()  { echo "  ${C_OK}[$MODE]${C_OFF} $*"; }
warn() { echo "  ${C_WARN}[!]${C_OFF} $*"; }
die()  { echo "${C_ERR}[fix-gdm-greeters] $HOST: $*${C_OFF}" >&2; exit 1; }

case "$MODE" in check|apply) ;; *) die "MODE doit valoir 'check' ou 'apply'." ;; esac
[ "$(id -u)" -eq 0 ] || die "doit tourner en root."

#------------------------------------------------------------------------------
# Declared UIDs, read from the running system
#------------------------------------------------------------------------------
#
# The activation script holds the exact perl command and users-groups.json
# of this generation: no UID hard-coded here, and `apply` replays that very
# command instead of a whole switch-to-configuration.

[ -r "$ACTIVATE" ] || die "$ACTIVATE introuvable."
USERS_CMD=$(grep -E '^\s*-w /nix/store/[^ ]+-update-users-groups\.pl /nix/store/[^ ]+-users-groups\.json' "$ACTIVATE" | head -n1)
PERL=$(grep -B1 -E '^\s*-w /nix/store/[^ ]+-update-users-groups\.pl' "$ACTIVATE" | grep -oE '/nix/store/[^ ]+/bin/perl' | head -n1)
USERS_PL=$(grep -oE '/nix/store/[^ ]+-update-users-groups\.pl' <<< "$USERS_CMD")
SPEC=$(grep -oE '/nix/store/[^ ]+-users-groups\.json' <<< "$USERS_CMD")
[ -x "$PERL" ] && [ -r "$USERS_PL" ] && [ -r "$SPEC" ] \
	|| die "commande update-users-groups introuvable dans $ACTIVATE."

# name<TAB>uid of every declared gdm-greeter* (JSON::PP ships with perl).
DECLARED=$("$PERL" -MJSON::PP -e '
	local $/; my $s = decode_json(<>);
	for my $u (@{ $s->{users} }) {
		printf "%s\t%s\n", $u->{name}, $u->{uid} // "" if $u->{name} =~ /^gdm-greeter/;
	}' "$SPEC")

if [ -z "$DECLARED" ]; then
	echo "=== $HOST: pas de GDM déclaré, rien à faire ==="
	exit 0
fi

#------------------------------------------------------------------------------
# Diagnosis
#------------------------------------------------------------------------------

declare -A WANT=()   # name -> declared uid
declare -A OLD=()    # shifted name -> uid on disk
declare -A REMAP=()  # old uid -> new uid, for the files they own

disk_uid() { awk -F: -v n="$1" '$1 == n { print $3 }' /etc/passwd; }

echo "=== $HOST: comptes gdm-greeter (mode=$MODE) ==="
while IFS=$'\t' read -r NAME UID_WANT; do
	[ -n "$UID_WANT" ] || { warn "$NAME : pas d'UID déclaré, ignoré"; continue; }
	WANT["$NAME"]="$UID_WANT"
	UID_DISK=$(disk_uid "$NAME")
	if [ -z "$UID_DISK" ]; then
		info "$NAME : absent, sera créé en $UID_WANT"
	elif [ "$UID_DISK" = "$UID_WANT" ]; then
		info "$NAME : $UID_DISK ok"
	else
		info "${C_WARN}$NAME : $UID_DISK sur disque, $UID_WANT déclaré${C_OFF}"
		OLD["$NAME"]="$UID_DISK"
	fi
done <<< "$DECLARED"

# Two accounts on one UID: the kernel sees one owner, the name depends on
# which /etc/passwd line comes first.
DUPS=$(awk -F: '{ c[$3]++; n[$3] = n[$3] " " $1 } END { for (u in c) if (c[u] > 1) print u ":" n[u] }' /etc/passwd)
[ -n "$DUPS" ] && while IFS= read -r D; do warn "UID dupliqué : $D"; done <<< "$DUPS"

if [ "${#OLD[@]}" -eq 0 ]; then
	echo "=== $HOST: OK, UID déjà alignés ==="
	exit 0
fi

# Once the shifted accounts are gone, only their declared UIDs must be free:
# perl does not check a declared UID against the remaining users.
for NAME in "${!OLD[@]}"; do
	U="${WANT[$NAME]}"
	HOLDERS=$(awk -F: -v u="$U" '$3 == u { print $1 }' /etc/passwd)
	for H in $HOLDERS; do
		[ -n "${OLD[$H]:-}" ] && continue
		[ "$H" = "$NAME" ] && continue
		die "UID $U voulu pour $NAME déjà tenu par $H (non décalé) : arrêt."
	done
done

# An old UID shared with an aligned account stays with that account; the
# files cannot be told apart, so they are left alone.
for NAME in "${!OLD[@]}"; do
	U="${OLD[$NAME]}"
	SHARED=0
	for N in "${!WANT[@]}"; do
		[ -z "${OLD[$N]:-}" ] && [ "${WANT[$N]}" = "$U" ] && SHARED=1
	done
	if [ "$SHARED" -eq 1 ]; then
		warn "fichiers de l'UID $U laissés tels quels (partagé avec un compte aligné)"
	else
		REMAP["$U"]="${WANT[$NAME]}"
	fi
done

#------------------------------------------------------------------------------
# Files owned by the old UIDs
#------------------------------------------------------------------------------
#
# Listed BEFORE any change: the shift is a chain (60580 goes from greeter-2 to
# greeter-3), afterwards ownership no longer tells who wrote what. /run/user
# dies with user@<uid>.service; /nix, homes and network mounts never hold them.

INVENTORY=$(mktemp -d)
trap 'rm -rf "$INVENTORY"' EXIT

if [ "${#REMAP[@]}" -gt 0 ]; then
	FIND_UIDS=()
	for U in "${!REMAP[@]}"; do FIND_UIDS+=(-o -uid "$U"); done
	for ROOT in / /var /tmp /run /boot; do
		[ -d "$ROOT" ] || continue
		find "$ROOT" -xdev \
			\( -path /nix -o -path /home -o -path /mnt -o -path /srv -o -path /run/user \) -prune \
			-o \( "${FIND_UIDS[@]:1}" \) -printf '%U\t%p\n' 2>/dev/null
	done | sort -u > "$INVENTORY/files"
	COUNT=$(wc -l < "$INVENTORY/files")
	info "fichiers à réattribuer : $COUNT"
	head -n 20 "$INVENTORY/files" | sed 's/^/    /'
	[ "$COUNT" -gt 20 ] && info "    …"
fi

for NAME in $(printf '%s\n' "${!OLD[@]}" | sort); do
	act "$NAME : ${OLD[$NAME]} -> ${WANT[$NAME]}"
done

if [ "$MODE" = "check" ]; then
	echo "=== $HOST: ${#OLD[@]} compte(s) à réaligner — relancer avec 'apply' ==="
	exit 0
fi

#------------------------------------------------------------------------------
# Apply
#------------------------------------------------------------------------------

# Stopping GDM kills the sessions it manages; greeter and ssh ones are fine.
for S in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{ print $1 }'); do
	CLASS=$(loginctl show-session "$S" -p Class --value)
	TYPE=$(loginctl show-session "$S" -p Type --value)
	USER_NAME=$(loginctl show-session "$S" -p Name --value)
	if [ "$CLASS" = "user" ] && { [ "$TYPE" = "wayland" ] || [ "$TYPE" = "x11" ]; }; then
		[ "$FORCE" = "1" ] || die "session graphique ouverte ($USER_NAME, $TYPE) : réessayer après déconnexion, ou FORCE=1."
		warn "session graphique de $USER_NAME fermée (FORCE=1)"
	fi
done

act "arrêt de display-manager"
systemctl stop display-manager.service

# Every greeter UID, old and new: their user managers outlive GDM a while.
GREETER_UIDS=$(awk -F: '$1 ~ /^gdm-greeter/ { print $3 }' /etc/passwd | sort -u)
for U in $GREETER_UIDS; do
	systemctl stop "user@$U.service" 2>/dev/null
done
for _ in $(seq 20); do
	LEFT=0
	for U in $GREETER_UIDS; do pgrep -u "$U" > /dev/null && LEFT=1; done
	[ "$LEFT" -eq 0 ] && break
	sleep 1
done
for U in $GREETER_UIDS; do pkill -KILL -u "$U" 2>/dev/null; done

act "sauvegarde dans $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
cp -a /etc/passwd /etc/shadow "$BACKUP_DIR/"
[ -f /var/lib/nixos/uid-map ] && cp -a /var/lib/nixos/uid-map "$BACKUP_DIR/"

restore() {
	cp -a "$BACKUP_DIR/passwd" "$BACKUP_DIR/shadow" /etc/
	[ -f "$BACKUP_DIR/uid-map" ] && cp -a "$BACKUP_DIR/uid-map" /var/lib/nixos/
	systemctl start display-manager.service
	die "$1 — fichiers restaurés depuis $BACKUP_DIR, GDM relancé."
}

# Write through a temp file + `cat >` to keep the inode, mode and owner.
NAMES_RE="^($(printf '%s\n' "${!OLD[@]}" | paste -sd'|')):"
for F in /etc/passwd /etc/shadow; do
	grep -vE "$NAMES_RE" "$F" > "$INVENTORY/$(basename "$F")" || restore "filtrage de $F"
	cat "$INVENTORY/$(basename "$F")" > "$F"
done
act "comptes retirés : ${!OLD[*]}"

act "update-users-groups (UID déclarés)"
"$PERL" -w "$USERS_PL" "$SPEC" 2>&1 | sed 's/^/    /'

for NAME in "${!WANT[@]}"; do
	GOT=$(disk_uid "$NAME")
	[ "$GOT" = "${WANT[$NAME]}" ] || restore "$NAME en '$GOT' au lieu de ${WANT[$NAME]}"
done

if [ -s "$INVENTORY/files" ]; then
	FAILED=0
	while IFS=$'\t' read -r U P; do
		chown -h "${REMAP[$U]}" -- "$P" 2>/dev/null || FAILED=$((FAILED + 1))
	done < "$INVENTORY/files"
	act "fichiers réattribués ($FAILED échec(s), disparus entre-temps en général)"
fi

act "démarrage de display-manager"
systemctl start display-manager.service
sleep 3
systemctl is-active --quiet display-manager.service || warn "display-manager inactif : voir journalctl -u display-manager"

echo "=== $HOST: ${#OLD[@]} compte(s) réaligné(s), sauvegarde $BACKUP_DIR ==="
exit 0
