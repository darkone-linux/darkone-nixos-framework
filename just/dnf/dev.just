# DNF just — framework development: dnf-only packages, temporary workarounds.

# Registry: `config/workarounds.nix`. Network: GitHub (gh) and cache.nixos.org.
#
# List temporary workarounds with their upstream status and drop candidates
[group('dev')]
workarounds:
	bash {{scriptsDir}}/workarounds.sh {{dnfDir}}

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

	# Nix 2.35: `nix flake metadata` no longer realises its `.path`, which
	# nix-update imports after each rewrite (Mic92/nix-update#687). Shim:
	# `nix flake prefetch` (same store path) realises it first.
	shim=$(mktemp -d)
	trap 'rm -rf "$shim"' EXIT
	realNix=$(command -v nix)
	cat >"$shim/nix" <<-EOF
	#!/usr/bin/env bash
	if [ "\${1-} \${2-}" = "flake metadata" ]; then
		"$realNix" --extra-experimental-features "nix-command flakes" flake prefetch --json . >/dev/null
	fi
	exec "$realNix" "\$@"
	EOF
	chmod +x "$shim/nix"

	# nix-update's `wrapProgram` prepends its own `nix`: a copy of the wrapper
	# re-puts the shim first, just before its final `exec`.
	updater=nix-update
	wrapper=$(readlink -f "$(command -v nix-update)")
	if grep -q '^exec ' "$wrapper"; then
		sed '/^exec /i PATH="'"$shim"':$PATH"; export PATH' "$wrapper" > "$shim/nix-update"
		chmod +x "$shim/nix-update"
		updater="$shim/nix-update"
	fi
	PATH="$shim:$PATH" "$updater" --flake "{{name}}" "${extra[@]}"
