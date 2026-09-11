# DNF just — consumer development: flake inputs.

# Update all flake inputs (dnf/ + root), commit and align locks
[group('dev')]
update-flake:
	#!/usr/bin/env bash
	set -euo pipefail

	# Co-development only: `dnf/` is a git checkout carrying its own lock, and
	# the dual-repo commit helpers of dev.just are imported. In release mode
	# `dnf/` is a read-only store symlink (or absent) — only the root lock moves.
	if [ ! -d "{{workDir}}/dnf/.git" ]; then
		just _log "Updating flake inputs..." "FLAKE"
		cd {{workDir}} && {{nix}} flake update
		exit 0
	fi
	just _log "Updating dnf/ flake inputs..." "FLAKE"
	(cd {{workDir}}/dnf && {{nix}} flake update)
	last_msg=$(git -C {{workDir}}/dnf log -1 --format=%s 2>/dev/null || echo "")
	if [[ "$last_msg" == "chore(flake):"* ]]; then
		just _log "Amending existing chore(flake) commit..." "FLAKE"
		just amend
	else

		# `chore`: routine input bumps are filtered out of the CHANGELOG.
		just commit "chore(flake): regular nixpkgs update"
	fi
	just _log "Updating root flake inputs..." "FLAKE"
	cd {{workDir}} && {{nix}} flake update
	just amend

# Refresh flake.lock's dnf input to the framework's HEAD (co-dev)
[group('dev')]
update-dnf:
	#!/usr/bin/env bash
	set -euo pipefail

	# Release mode (no dnf/ checkout): framework pinned to a remote rev, nothing
	# local to track — leave the lock untouched.
	if [ ! -d "{{workDir}}/dnf/.git" ]; then
		just _info "No dnf/ checkout — leaving lock untouched." "FLAKE"
		exit 0
	fi
	cd {{workDir}}
	head=$(git -C dnf rev-parse HEAD)
	locked=$({{nix}} eval --raw --impure --expr '(builtins.fromJSON (builtins.readFile "{{workDir}}/flake.lock")).nodes.dnf.locked.rev or ""' 2>/dev/null || echo "")

	# git+file: only deploys committed state; warn so dirty edits aren't silently skipped.
	if ! git -C dnf diff --quiet || ! git -C dnf diff --cached --quiet; then
		just _warn "dnf/ has uncommitted changes — commit them before apply to deploy them."
	fi
	if [ "$locked" = "$head" ]; then
		just _info "dnf lock already up to date." "FLAKE"
	else
		just _log "Refreshing dnf lock..." "FLAKE"
		{{nix}} flake update dnf
	fi
