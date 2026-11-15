# FFFF half of the pairing code (`just/scripts/pair-fingerprint.sh`), pinned.
#
# The installer ISO prints it, the admin host recomputes it from `ssh-keyscan`:
# a drift on either side refuses every pairing. Checks two pinned vectors, the
# input forms of both sides, the OpenSSH `SHA256:` fingerprint as an
# independent derivation, and the refusals.

{ pkgs, ... }:
let
  script = ../../../just/scripts/pair-fingerprint.sh;

  # Key blobs and their digits; the second one checks the zero padding.
  blobA = "AAAAC3NzaC1lZDI1NTE5AAAAINnLJ1AefW4r5mHcUR1+nllS+yRY7Mynrv0jdiamsqPt";
  blobB = "AAAAC3NzaC1lZDI1NTE5AAAAIDbxOleKULIZkltOW+VjIPhfvLLWwsmTMuS1LkBHMrwD";
in
pkgs.runCommand "pair-fingerprint-check"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.openssh
    ];
  }
  ''
    set -euo pipefail
    run() { bash ${script} "$@"; }
    expect() {
      if [ "$1" != "$2" ]; then
        echo "FAIL: $3: got '$1', expected '$2'" >&2
        exit 1
      fi
    }

    # ISO side: the host key file, its comment included.
    printf 'ssh-ed25519 %s root@dnf-install\n' ${blobA} > a.pub
    expect "$(run a.pub)" 2428 "host key file"
    expect "$(run < a.pub)" 2428 "host key on stdin"
    expect "$(printf 'ssh-ed25519 %s' ${blobB} | run)" 0008 "no newline, zero padding"

    # Admin side: `ssh-keyscan` lines, banner comments, other key types, and
    # the same key twice (one line per address of the host).
    {
      echo "# 10.0.2.15:22 SSH-2.0-OpenSSH_10.6"
      echo "10.0.2.15 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ"
      echo "10.0.2.15 ssh-ed25519 ${blobA}"
      echo "fe80::1 ssh-ed25519 ${blobA}"
    } > scan.txt
    expect "$(run < scan.txt)" 2428 "ssh-keyscan output"

    # Independent derivation: the base64 `SHA256:` fingerprint of OpenSSH.
    for blob in ${blobA} ${blobB}; do
      printf 'ssh-ed25519 %s\n' "$blob" > k.pub
      fp="$(ssh-keygen -l -E sha256 -f k.pub | cut -d' ' -f2)"
      hex="$(printf '%s=' "''${fp#SHA256:}" | base64 -d | od -An -tx1 | tr -d ' \n')"
      expect "$(run k.pub)" "$(printf '%04d' "$((16#''${hex:0:8} % 10000))")" "ssh-keygen fingerprint"
    done

    # Refusals: no key, two different keys, a truncated blob.
    for input in "# nothing" \
      "$(printf 'h ssh-ed25519 %s\nh ssh-ed25519 %s' ${blobA} ${blobB})" \
      "h ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINnLJ1Ae"; do
      if printf '%s\n' "$input" | run > /dev/null 2>&1; then
        echo "FAIL: accepted: $input" >&2
        exit 1
      fi
    done

    touch $out
  ''
