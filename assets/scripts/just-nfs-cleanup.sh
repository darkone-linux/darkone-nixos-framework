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

# Repatriate a directory across btrfs subvolumes. `/home` and `/srv` are two
# subvolumes of the same filesystem, so rename() returns EXDEV; a reflink copy
# is near-free there and degrades to a plain copy anywhere else.
repatriate() {
	local src="$1" dst="$2" owner="$3"
	cp -a --reflink=auto -T -- "$src" "$dst" || return 1
	local a b
	a=$(du -s --apparent-size -- "$src" 2>/dev/null | cut -f1)
	b=$(du -s --apparent-size -- "$dst" 2>/dev/null | cut -f1)
	[ "$a" = "$b" ] || { echo "size mismatch $a != $b" >&2; return 1; }
	chown -R -- "$owner:users" "$dst" || return 1
	rm -rf -- "$src"
}

#------------------------------------------------------------------------------
# Guards
#------------------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || die "must run as root."
case "$MODE" in check|apply) ;; *) die "unknown mode '$MODE' (check|apply)." ;; esac

# NFS must already be off: while /mnt/nfs/homes is mounted the links are alive
# and indistinguishable from the server's own.
if mountpoint -q "$MNT_NFS/homes" ; then
	die "$MNT_NFS/homes is still mounted — disable NFS and re-apply this host first."
fi

IS_SERVER=0
[ -d "$SRV_NFS/homes" ] && IS_SERVER=1

echo "=== nfs-cleanup on $(hostname) — mode=$MODE, server=$IS_SERVER ==="

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

	for KIND in $KINDS; do
		read -ra ALL <<< "$(names_of "$KIND")"
		PRESENT=()
		FULL=()
		for NAME in "${ALL[@]}"; do
			P="$HOME_DIR/$NAME"
			p_isdir "$P" || continue
			PRESENT+=("$NAME")
			p_empty "$P" || FULL+=("$NAME")
		done
		[ "${#PRESENT[@]}" -gt 1 ] || continue

		if [ "${#FULL[@]}" -gt 1 ]; then
			warn "$KIND: doublons non vides (${FULL[*]}) — arbitrage manuel"
			continue
		fi

		# Nothing to arbitrate: keep the one holding data, else the fr_FR name.
		KEEP="${ALL[0]}"
		[ "${#FULL[@]}" -eq 1 ] && KEEP="${FULL[0]}"

		for NAME in "${PRESENT[@]}"; do
			[ "$NAME" = "$KEEP" ] && continue
			act "rmdir $NAME (vide, doublon de $KEEP)"
			run rmdir -- "$HOME_DIR/$NAME"
			mark_gone "$HOME_DIR/$NAME"
		done
	done

	#--------------------------------------------------------------------------
	# 4. Regenerate XDG dirs for the current locale
	#--------------------------------------------------------------------------
	#
	# XDG_DATA_DIRS is what `nfs.nix` had to set for xdg-user-dirs-update to
	# find its .mo files — its absence is exactly what produced the English
	# names being cleaned up above.

	XDU=$(command -v xdg-user-dirs-update || true)
	if [ -z "$XDU" ]; then
		warn "xdg-user-dirs-update absent, régénération XDG sautée"
	else
		XDG_SHARE="$(dirname "$(dirname "$(readlink -f "$XDU")")")/share"

		# Which kinds no longer have any directory at all. The exact names come
		# from xdg-user-dirs and its locale, not from the table above, so they
		# are named by kind here rather than guessed.
		MISSING=()
		for KIND in $KINDS; do
			read -ra ALL <<< "$(names_of "$KIND")"
			FOUND=0
			for NAME in "${ALL[@]}"; do
				p_isdir "$HOME_DIR/$NAME" && FOUND=1 && break
			done
			[ "$FOUND" -eq 0 ] && MISSING+=("$KIND")
		done
		if [ "${#MISSING[@]}" -gt 0 ]; then
			act "régénère les répertoires XDG (recrée : ${MISSING[*]})"
		else
			act "régénère user-dirs.dirs (tous les répertoires sont déjà là)"
		fi

		# One child shell as the user: `user-dirs.dirs` holds `$HOME`-relative
		# values, so it must be sourced with that user's HOME, never root's.
		if [ "$MODE" = "apply" ]; then

			# shellcheck disable=SC2016 # expanded by the child shell, not here
			runuser -u "$USER_NAME" -- env "HOME=$HOME_DIR" "XDG_DATA_DIRS=$XDG_SHARE" \
				bash -c '
					rm -f "$HOME/.config/user-dirs.dirs" "$HOME/.config/user-dirs.locale"
					"$1" --force
					[ -f "$HOME/.config/user-dirs.dirs" ] || exit 0
					. "$HOME/.config/user-dirs.dirs"
					for D in "${XDG_DESKTOP_DIR:-}" "${XDG_DOCUMENTS_DIR:-}" \
					         "${XDG_DOWNLOAD_DIR:-}" "${XDG_MUSIC_DIR:-}" \
					         "${XDG_PICTURES_DIR:-}" "${XDG_PUBLICSHARE_DIR:-}" \
					         "${XDG_TEMPLATES_DIR:-}" "${XDG_VIDEOS_DIR:-}" ;do
						[ -n "$D" ] || continue

						# A leftover foreign symlink under an XDG name makes
						# `mkdir -p` fail on a path that is not ours to fix.
						[ -e "$D" ] || [ -L "$D" ] || mkdir -p -- "$D"
					done
				' _ "$XDU" || warn "$USER_NAME: régénération XDG en échec"
		fi
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
echo "=== $(hostname): $ACTIONS action(s), $WARNINGS avertissement(s) — mode=$MODE ==="
[ "$MODE" = "check" ] && echo "    (aucune écriture ; relancer avec 'apply' pour exécuter)"
exit 0
