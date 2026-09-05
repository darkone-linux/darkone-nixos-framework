# Decision table of `assets/scripts/just-nfs-cleanup.sh`, pinned.
#
# The script removes symlinks, moves user data and deletes directories: a
# regression there costs files, not a red tick. Three bugs found while writing
# it are locked down here — a non-predictive `check`, a share directory reached
# by two localized names being repatriated twice, and leftovers reported from
# sources the run had already moved.
#
# Runs the script in `check` mode only: it writes nothing, needs no root, and
# carries the whole decision table. `apply` executes the very same list, which
# the report equality below is the proof of.

{ pkgs, ... }:
let

  # Every name that appears in the report is normalized: the sandbox build user,
  # the temporary root, and `du` sizes, which are filesystem-dependent.
  expected = ''
    === CLIENT ===
      [!] Bureau -> /some/where/else : lien étranger, laissé en place
      [check] rm Documents -> TMP/mnt/nfs/homes/USER/Documents
      [check] rm Images -> TMP/mnt/nfs/homes/USER/Pictures
      [check] rm Pictures -> TMP/mnt/nfs/homes/USER/Pictures
      [check] rm Public -> TMP/mnt/nfs/common
      [check] restaure Documents.bak -> Documents (N)
      [check] restaure Images.bak -> Images (N)
      [check] restaure Pictures.bak -> Pictures (N)
      [check] rmdir Pictures (vide, doublon de Images)
      [check] régénère les répertoires XDG (recrée : DESKTOP DOWNLOAD MUSIC PUBLICSHARE TEMPLATES VIDEOS)
      [check] rm .config/gtk-3.0/bookmarks (signets vers le partage)
    === SERVER ===
      [check] rapatrie TMP/srv/nfs/homes/USER/Documents (N) -> Documents
      [check] rapatrie TMP/srv/nfs/homes/USER/Pictures (N) -> Images
      [check] rm Pictures -> TMP/srv/nfs/homes/USER/Pictures (déjà rapatrié dans Images)
      [check] rm Public -> TMP/srv/nfs/common (partage commun, données laissées en place)
      [check] régénère les répertoires XDG (recrée : DESKTOP DOWNLOAD MUSIC PUBLICSHARE TEMPLATES VIDEOS)
      [!] reste dans le partage : TMP/srv/nfs/homes/USER/Desktop (N) — aucun lien ne le réclamait
  '';
in
pkgs.runCommand "nfs-cleanup-check"
  {
    nativeBuildInputs = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      gnused
      util-linux
      xdg-user-dirs
    ];
    script = ../../../assets/scripts/just-nfs-cleanup.sh;
    expected = builtins.toFile "expected.txt" expected;
  }
  ''
    set -euo pipefail
    export HOME=$TMPDIR
    U=$(id -un)

    #-------------------------------------------------------------------------
    # Fixtures
    #-------------------------------------------------------------------------

    # Client: the share is unmounted, so every link is dead. `Images` and
    # `Pictures` are the locale slip; `Bureau` is somebody else's symlink.
    C=$TMPDIR/client
    mkdir -p "$C"/{mnt/nfs,homes/"$U"/.config/gtk-3.0}
    H=$C/homes/$U
    ln -s "$C/mnt/nfs/homes/$U/Documents" "$H/Documents"
    ln -s "$C/mnt/nfs/homes/$U/Pictures"  "$H/Images"
    ln -s "$C/mnt/nfs/homes/$U/Pictures"  "$H/Pictures"
    ln -s "$C/mnt/nfs/common"             "$H/Public"
    ln -s /some/where/else                "$H/Bureau"
    mkdir -p "$H/Documents.bak" "$H/Images.bak" "$H/Pictures.bak"
    echo doc > "$H/Documents.bak/note.txt"
    echo pic > "$H/Images.bak/a.jpg"
    printf 'file://%s\n' "$C/mnt/nfs/homes/$U/Documents" > "$H/.config/gtk-3.0/bookmarks"

    # Server: links are alive and hold the data. `Desktop` is in the share with
    # no link pointing at it — nothing claims it, so nothing must move it.
    S=$TMPDIR/server
    mkdir -p "$S"/{srv/nfs/common,homes/"$U"}
    G=$S/homes/$U
    for d in Documents Pictures Desktop; do mkdir -p "$S/srv/nfs/homes/$U/$d"; done
    echo doc      > "$S/srv/nfs/homes/$U/Documents/rapport.odt"
    echo pic      > "$S/srv/nfs/homes/$U/Pictures/vacances.jpg"
    echo oublie   > "$S/srv/nfs/homes/$U/Desktop/oublie.txt"
    echo commun   > "$S/srv/nfs/common/partage.txt"
    ln -s "$S/srv/nfs/homes/$U/Documents" "$G/Documents"
    ln -s "$S/srv/nfs/homes/$U/Pictures"  "$G/Images"
    ln -s "$S/srv/nfs/homes/$U/Pictures"  "$G/Pictures"
    ln -s "$S/srv/nfs/common"             "$G/Public"

    #-------------------------------------------------------------------------
    # Run
    #-------------------------------------------------------------------------

    # Keep only the action and warning lines (two leading spaces), and erase
    # what is environment-dependent: build user, temp root, `du` sizes.
    report() {
      grep '^  \[' \
        | sed -e "s|$TMPDIR/[a-z]*|TMP|g" -e "s|\b$U\b|USER|g" -e 's|(\([0-9,.]*[KMG]\?\))|(N)|g'
    }

    before=$(find "$C" "$S" -printf '%y %p -> %l\n' | sort)

    {
      echo "=== CLIENT ==="
      MODE=check HOMES_ROOT=$C/homes SRV_NFS=$C/srv/nfs MNT_NFS=$C/mnt/nfs \
        bash "$script" | report
      echo "=== SERVER ==="
      MODE=check HOMES_ROOT=$S/homes SRV_NFS=$S/srv/nfs MNT_NFS=$S/mnt/nfs \
        bash "$script" | report
    } > got.txt

    #-------------------------------------------------------------------------
    # Assertions
    #-------------------------------------------------------------------------

    if ! diff -u "$expected" got.txt ;then
      echo "FAIL: le rapport du mode check a changé (voir le diff ci-dessus)." >&2
      exit 1
    fi

    # `check` must not write: the guarantee the whole dry-run rests on.
    after=$(find "$C" "$S" -printf '%y %p -> %l\n' | sort)
    if [ "$before" != "$after" ] ;then
      echo "FAIL: le mode check a modifié l'arborescence." >&2
      diff <(echo "$before") <(echo "$after") >&2 || true
      exit 1
    fi

    # Guards. The sandbox runs unprivileged, which is exactly what the
    # apply-needs-root check must refuse.
    if MODE=apply HOMES_ROOT=$C/homes SRV_NFS=$C/srv/nfs MNT_NFS=$C/mnt/nfs \
         bash "$script" >/dev/null 2>&1 ;then
      echo "FAIL: apply accepté sans les droits root." >&2
      exit 1
    fi
    if MODE=bogus HOMES_ROOT=$C/homes bash "$script" >/dev/null 2>&1 ;then
      echo "FAIL: mode inconnu accepté." >&2
      exit 1
    fi

    touch $out
  ''
