# DNF just — framework development: dnf-only packages.

# Bump a dnf/pkgs derivation to its latest upstream release
[group('dev')]
pkg-update name:
	#!/usr/bin/env bash
	set -euo pipefail

	# nix-update rewrites `version` and the hashes in `package.nix`: a `dnf/`
	# symlinked from the nix store is read-only, so it needs a real checkout.
	if [ ! -w "{{dnfDir}}/pkgs/{{name}}" ] ;then
		just _fail "dnf/pkgs/{{name}}: absent or read-only"
	fi
	just _log "Updating {{name}}..." "NIX-UPDATE"
	cd "{{dnfDir}}" && nix-update --flake "{{name}}"
