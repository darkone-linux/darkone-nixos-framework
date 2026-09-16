# DNF just — framework development: dnf-only packages.

# Bump a dnf/pkgs derivation to its latest upstream release, or to `version`
[group('dev')]
pkg-update name version="":
	#!/usr/bin/env bash
	set -euo pipefail

	# nix-update rewrites `version` and the hashes in `package.nix`: a `dnf/`
	# symlinked from the nix store is read-only, so it needs a real checkout.
	if [ ! -w "{{dnfDir}}/pkgs/{{name}}" ] ;then
		just _fail "dnf/pkgs/{{name}}: absent or read-only"
	fi
	just _log "Updating {{name}}..." "NIX-UPDATE"
	cd "{{dnfDir}}"

	# Extra args of `passthru.updateScript` (`nix-update-script` list), e.g.
	# `--subpackage node_modules`: packages keep the nixpkgs convention.
	mapfile -t extra < <({{nix}} eval --raw ".#{{name}}" --apply '
		p: let s = p.passthru.updateScript or [ "" ];
		in builtins.concatStringsSep "\n" (builtins.tail (if builtins.isList s then s else s.command or [ "" ]))
	')

	# Explicit version (release train): a tag pushed seconds ago may not be
	# listed upstream yet.
	[ -z "{{version}}" ] || extra+=("--version={{version}}")
	nix-update --flake "{{name}}" "${extra[@]}"
