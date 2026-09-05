#!/usr/bin/env bash
#
# Undo, in every /home/*, what `home/profiles/minimal/nfs.nix` did: XDG user
# directories replaced by symlinks into the NFS share, the previous content
# parked as `<dir>.bak`, and GTK bookmarks pointing at those links.
#
# Run via `just nfs-cleanup <host>[,<host>...] [check|apply]`, which pipes this
# file to `sudo bash -s` on each node. `check` (default) writes nothing.
#
#  - client (link -> /mnt/nfs/...)      : link removed, target is gone anyway
#  - server (link -> /srv/nfs/homes/..) : data repatriated into the home
#  - PUBLICSHARE (-> .../common)        : link removed, shared data left alone
#  - `<dir>.bak`                        : restored when the name is free
#  - FR/EN duplicates                   : the empty one is dropped, never a
#                                         non-empty one (both full = reported)
#
# Scope is the FIRST LEVEL of each home and the XDG names below, nothing else:
# `~/.local/share/supertuxkart/addons/tracks` also points into /mnt/nfs and
# must survive.
#
# Idempotent: a second run finds nothing left to do.

set -uo pipefail

MODE="${MODE:-check}"
SRV_NFS="${SRV_NFS:-/srv/nfs}"
MNT_NFS="${MNT_NFS:-/mnt/nfs}"
HOMES_ROOT="${HOMES_ROOT:-/home}"

#------------------------------------------------------------------------------
# XDG kinds and their localized names
#------------------------------------------------------------------------------
#
# First name of each list is the fr_FR one, i.e. the name the fleet's locale
# asks for; the rest are the English leftovers of the activations that ran
# without XDG_DATA_DIRS and produced untranslated names.

KINDS="DESKTOP DOCUMENTS DOWNLOAD MUSIC PICTURES PUBLICSHARE TEMPLATES VIDEOS"

names_of() {
	case "$1" in
		DESKTOP)     echo "Bureau Desktop" ;;
		DOCUMENTS)   echo "Documents" ;;
		DOWNLOAD)    echo "Téléchargements Downloads Téléchargement" ;;
		MUSIC)       echo "Musique Music" ;;
		PICTURES)    echo "Images Pictures" ;;
		PUBLICSHARE) echo "Public" ;;
		TEMPLATES)   echo "Modèles Templates" ;;
		VIDEOS)      echo "Vidéos Videos" ;;
	esac
}

#------------------------------------------------------------------------------
# Output
#------------------------------------------------------------------------------

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_OK=""; C_WARN=""; C_ERR=""; C_OFF=""; }

ACTIONS=0
WARNINGS=0
TOTAL_KB=0

is_empty_dir() { [ -z "$(ls -A -- "$1" 2>/dev/null)" ]; }

act()  { ACTIONS=$((ACTIONS + 1)); echo "  ${C_OK}[$MODE]${C_OFF} $*"; }
warn() { WARNINGS=$((WARNINGS + 1)); echo "  ${C_WARN}[!]${C_OFF} $*"; }
die()  { echo "${C_ERR}[nfs-cleanup] $*${C_OFF}" >&2; exit 1; }

run() { [ "$MODE" = "apply" ] || return 0; "$@"; }

#------------------------------------------------------------------------------
# Simulation layer
#------------------------------------------------------------------------------
#
# `check` must print exactly what `apply` would do, so every step reads the
# state through these predicates rather than the filesystem: without them step 2
# still saw the symlinks step 1 only *said* it would remove, and reported a
# conflict on every single `.bak`.

declare -A GONE=()
declare -A MADE=()
declare -A EMPTY=()
declare -A CLAIMED=()

mark_gone() { GONE["$1"]=1; unset "MADE[$1]" "EMPTY[$1]"; }
mark_made() { MADE["$1"]=1; EMPTY["$1"]="$2"; unset "GONE[$1]"; }

p_exists() {
	[ -n "${MADE[$1]:-}" ] && return 0
	[ -n "${GONE[$1]:-}" ] && return 1
	[ -e "$1" ] || [ -L "$1" ]
}

p_isdir() {
	[ -n "${MADE[$1]:-}" ] && return 0
	[ -n "${GONE[$1]:-}" ] && return 1
	[ -d "$1" ] && [ ! -L "$1" ]
}

p_islink() {
	{ [ -n "${MADE[$1]:-}" ] || [ -n "${GONE[$1]:-}" ]; } && return 1
	[ -L "$1" ]
}

p_empty() {
	[ -n "${EMPTY[$1]:-}" ] && { [ "${EMPTY[$1]}" = 1 ]; return; }
	is_empty_dir "$1"
}

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------

human() { du -sh --apparent-size -- "$1" 2>/dev/null | cut -f1; }

# Free space, in KiB, of the filesystem holding `$1`.
avail_kb() { df -Pk -- "$1" | awk 'NR == 2 { print $4 }'; }

# Apparent size, in KiB.
size_kb() { du -s --apparent-size -- "$1" 2>/dev/null | cut -f1; }

# Move a share directory back into the home, cheapest way first.
#
# `/home` and `/srv` are usually two subvolumes of one btrfs: rename() returns
# EXDEV, but a reflink shares the extents instead of duplicating them. Which
# matters — the share can hold far more than the filesystem has free, and
# `--reflink=auto` would degrade to a full copy without saying a word.
repatriate() {
	local src="$1" dst="$2" owner="$3"

	# Same subvolume: instant, no space, nothing to verify afterwards.
	if mv -T -- "$src" "$dst" 2>/dev/null; then
		chown -R -- "$owner:users" "$dst"
		return
	fi

	# Same filesystem, different subvolume: extents shared, near-free.
	if ! cp -a --reflink=always -T -- "$src" "$dst" 2>/dev/null; then

		# Genuinely distinct filesystems: a real copy, so refuse to start one
		# that cannot finish rather than fill the disk halfway through.
		local need avail
		need=$(size_kb "$src")
		avail=$(avail_kb "$(dirname -- "$dst")")
		if [ "${need:-0}" -ge "${avail:-0}" ]; then
			echo "not enough free space: ${need}K needed, ${avail}K available" >&2
			return 1
		fi
		cp -a -T -- "$src" "$dst" || return 1
	fi

	local a b
	a=$(size_kb "$src")
	b=$(size_kb "$dst")
	[ "$a" = "$b" ] || { echo "size mismatch $a != $b" >&2; return 1; }
	chown -R -- "$owner:users" "$dst" || return 1
	rm -rf -- "$src"
}

#------------------------------------------------------------------------------
# Duplicate purge
#------------------------------------------------------------------------------
#
# Runs twice: once after the `.bak` restores, once after xdg-user-dirs has
# recreated what the locale wants — which itself creates duplicates when an
# English leftover held the kind on its own.

purge_duplicates() {
	local home="$1" kind name keep p
	local -a all present full

	for kind in $KINDS; do
		read -ra all <<< "$(names_of "$kind")"
		present=()
		full=()
		for name in "${all[@]}"; do
			p="$home/$name"
			p_isdir "$p" || continue
			present+=("$name")
			p_empty "$p" || full+=("$name")
		done
		[ "${#present[@]}" -gt 1 ] || continue

		if [ "${#full[@]}" -gt 1 ]; then
			warn "$kind: doublons non vides (${full[*]}) — arbitrage manuel"
			continue
		fi

		# Keep the one holding data; failing that, the name this locale wants.
		keep="${LOCALE_NAME[$kind]:-${all[0]}}"
		[ "${#full[@]}" -eq 1 ] && keep="${full[0]}"

		for name in "${present[@]}"; do
			[ "$name" = "$keep" ] && continue
			act "rmdir $name (vide, doublon de $keep)"
			run rmdir -- "$home/$name"
			mark_gone "$home/$name"
		done
	done
}

#------------------------------------------------------------------------------
# Guards
#------------------------------------------------------------------------------

case "$MODE" in check|apply) ;; *) die "unknown mode '$MODE' (check|apply)." ;; esac
[ "$MODE" = "check" ] || [ "$(id -u)" -eq 0 ] || die "apply must run as root."

# NFS must already be off: while /mnt/nfs/homes is mounted the links are alive
# and indistinguishable from the server's own.
if mountpoint -q "$MNT_NFS/homes" ; then
	die "$MNT_NFS/homes is still mounted — disable NFS and re-apply this host first."
fi

IS_SERVER=0
[ -d "$SRV_NFS/homes" ] && IS_SERVER=1

#------------------------------------------------------------------------------
# Locale probe
#------------------------------------------------------------------------------
#
# Ask xdg-user-dirs itself which name each kind takes here, in a throwaway HOME.
# The table above only says which names to *consider*; guessing which one the
# locale wants would hardcode fr_FR into the decision logic.

XDU=$(command -v xdg-user-dirs-update || true)
declare -A LOCALE_NAME=()

if [ -n "$XDU" ]; then
	XDG_SHARE="$(dirname "$(dirname "$(readlink -f "$XDU")")")/share"
	PROBE=$(mktemp -d)
	trap 'rm -rf -- "$PROBE"' EXIT
	HOME="$PROBE" XDG_DATA_DIRS="$XDG_SHARE" "$XDU" --force >/dev/null 2>&1 || true
	if [ -f "$PROBE/.config/user-dirs.dirs" ]; then

		# shellcheck disable=SC1091 # generated file, read in a subshell HOME
		while IFS='=' read -r K V; do
			case "$K" in XDG_*_DIR) ;; *) continue ;; esac
			K=${K#XDG_}; K=${K%_DIR}
			V=${V%\"}; V=${V##*/}
			[ -n "$V" ] && LOCALE_NAME["$K"]="$V"
		done < "$PROBE/.config/user-dirs.dirs"
	fi
fi

echo "=== nfs-cleanup on ${HOSTNAME:-$(uname -n)} — mode=$MODE, server=$IS_SERVER ==="

#------------------------------------------------------------------------------
# Per-home pass
#------------------------------------------------------------------------------

for HOME_DIR in "$HOMES_ROOT"/*; do
	[ -d "$HOME_DIR" ] || continue
	[ -L "$HOME_DIR" ] && continue
	USER_NAME=$(basename -- "$HOME_DIR")
	id -u -- "$USER_NAME" >/dev/null 2>&1 || { warn "$USER_NAME: no such user, skipped"; continue; }

	echo
	echo "--- $USER_NAME ($HOME_DIR)"
	CLAIMED=()

	#--------------------------------------------------------------------------
	# 1. Our symlinks
	#--------------------------------------------------------------------------

	for KIND in $KINDS; do
		for NAME in $(names_of "$KIND"); do
			P="$HOME_DIR/$NAME"
			p_islink "$P" || continue
			TARGET=$(readlink -- "$P")

			case "$TARGET" in
				"$MNT_NFS"/*)
					act "rm $NAME -> $TARGET"
					run rm -f -- "$P"
					mark_gone "$P"
					;;
				"$SRV_NFS"/common|"$SRV_NFS"/common/*)

					# Shared data, not this user's: unlink, never copy.
					act "rm $NAME -> $TARGET (partage commun, données laissées en place)"
					run rm -f -- "$P"
					mark_gone "$P"
					;;
				"$SRV_NFS"/homes/"$USER_NAME"/*)

					# A locale slip left two names on one share directory
					# (Images *and* Pictures -> .../Pictures). Repatriate it
					# once, under the first name the table lists, and drop the
					# other link — copying twice would race its own `rm -rf`.
					if [ -n "${CLAIMED[$TARGET]:-}" ]; then
						act "rm $NAME -> $TARGET (déjà rapatrié dans ${CLAIMED[$TARGET]})"
						run rm -f -- "$P"
						mark_gone "$P"
						continue
					fi
					if [ -d "$TARGET" ]; then
						SRC_EMPTY=0
						is_empty_dir "$TARGET" && SRC_EMPTY=1
						TOTAL_KB=$((TOTAL_KB + $(size_kb "$TARGET")))
						act "rapatrie $TARGET ($(human "$TARGET")) -> $NAME"
						run rm -f -- "$P"
						if [ "$MODE" = "apply" ] && ! repatriate "$TARGET" "$P" "$USER_NAME"; then
							warn "$NAME: rapatriement échoué, source conservée"
							mark_gone "$P"
							continue
						fi
						mark_made "$P" "$SRC_EMPTY"
						mark_gone "$TARGET"
						CLAIMED["$TARGET"]="$NAME"
					else
						act "rm $NAME -> $TARGET (cible absente)"
						run rm -f -- "$P"
						mark_gone "$P"
					fi
					;;
				*)
					warn "$NAME -> $TARGET : lien étranger, laissé en place"
					;;
			esac
		done
	done

	#--------------------------------------------------------------------------
	# 2. Restore <dir>.bak
	#--------------------------------------------------------------------------

	for KIND in $KINDS; do
		for NAME in $(names_of "$KIND"); do
			BAK="$HOME_DIR/$NAME.bak"
			p_isdir "$BAK" || continue
			P="$HOME_DIR/$NAME"
			if p_exists "$P"; then
				warn "$NAME.bak: '$NAME' existe déjà ($(human "$BAK")), .bak conservé"
			else
				SRC_EMPTY=0
				is_empty_dir "$BAK" && SRC_EMPTY=1
				act "restaure $NAME.bak -> $NAME ($(human "$BAK"))"
				run mv -T -- "$BAK" "$P"
				mark_made "$P" "$SRC_EMPTY"
				mark_gone "$BAK"
			fi
		done
	done

	#--------------------------------------------------------------------------
	# 3. Drop empty FR/EN duplicates
	#--------------------------------------------------------------------------

	purge_duplicates "$HOME_DIR"

	#--------------------------------------------------------------------------
	# 4. Regenerate XDG dirs for the current locale
	#--------------------------------------------------------------------------
	#
	# XDG_DATA_DIRS is what `nfs.nix` had to set for xdg-user-dirs-update to
	# find its .mo files — its absence is exactly what produced the English
	# names being cleaned up above.

	if [ -z "$XDU" ]; then
		warn "xdg-user-dirs-update absent, régénération XDG sautée"
	else

		# It rewrites user-dirs.dirs — which still names the links just removed —
		# and creates every directory the locale wants, English leftover or not.
		CREATED=()
		for KIND in $KINDS; do
			NAME="${LOCALE_NAME[$KIND]:-}"
			[ -n "$NAME" ] || continue
			p_exists "$HOME_DIR/$NAME" && continue
			CREATED+=("$NAME")
			mark_made "$HOME_DIR/$NAME" 1
		done
		if [ "${#CREATED[@]}" -gt 0 ]; then
			act "régénère user-dirs.dirs (crée : ${CREATED[*]})"
		else
			act "régénère user-dirs.dirs (tous les répertoires sont déjà là)"
		fi

		# shellcheck disable=SC2016 # expanded by the child shell, not here
		if [ "$MODE" = "apply" ]; then
			runuser -u "$USER_NAME" -- env "HOME=$HOME_DIR" "XDG_DATA_DIRS=$XDG_SHARE" \
				bash -c '
					rm -f "$HOME/.config/user-dirs.dirs" "$HOME/.config/user-dirs.locale"
					"$1" --force
				' _ "$XDU" || warn "$USER_NAME: régénération XDG en échec"
		fi

		# Second pass: the creation above can pair a fresh locale-named
		# directory with an English one that held the kind alone.
		purge_duplicates "$HOME_DIR"
	fi

	#--------------------------------------------------------------------------
	# 5. GTK bookmarks
	#--------------------------------------------------------------------------
	#
	# Written by `nfs.nix` and pointing at the links just removed; nobody owns
	# it any more, so let GNOME fall back to its defaults.

	BM="$HOME_DIR/.config/gtk-3.0/bookmarks"
	if [ -f "$BM" ] && grep -qE "file://($MNT_NFS|$SRV_NFS)/" "$BM" 2>/dev/null; then
		act "rm .config/gtk-3.0/bookmarks (signets vers le partage)"
		run rm -f -- "$BM"
	fi

	#--------------------------------------------------------------------------
	# 6. Leftovers in the share
	#--------------------------------------------------------------------------
	#
	# Nothing is lost when no link claimed a share directory — but nothing says
	# so either, and the whole point of the pass is to empty /srv/nfs/homes.

	SHARE="$SRV_NFS/homes/$USER_NAME"
	if [ "$IS_SERVER" -eq 1 ] && [ -d "$SHARE" ]; then
		while IFS= read -r LEFT; do
			[ -n "$LEFT" ] || continue
			[ -n "${GONE[$LEFT]:-}" ] && continue
			is_empty_dir "$LEFT" && continue
			warn "reste dans le partage : $LEFT ($(human "$LEFT")) — aucun lien ne le réclamait"
		done < <(find "$SHARE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
	fi
done

echo
echo "=== ${HOSTNAME:-$(uname -n)}: $ACTIONS action(s), $WARNINGS avertissement(s) — mode=$MODE ==="

# The share routinely holds more than the target filesystem has free: say so
# up front, since only a same-btrfs reflink makes that a non-issue.
if [ "$TOTAL_KB" -gt 0 ]; then
	AVAIL_KB=$(avail_kb "$HOMES_ROOT")
	echo "    à rapatrier : $(numfmt --to=iec --from-unit=1024 "$TOTAL_KB")" \
		"| libre sur $HOMES_ROOT : $(numfmt --to=iec --from-unit=1024 "$AVAIL_KB")"
	if [ "$TOTAL_KB" -ge "${AVAIL_KB:-0}" ]; then
		echo "    ${C_WARN}le partage dépasse la place libre : seul un reflink (même btrfs) rend l'opération possible${C_OFF}"
	fi
fi
[ "$MODE" = "check" ] && echo "    (aucune écriture ; relancer avec 'apply' pour exécuter)"
exit 0
