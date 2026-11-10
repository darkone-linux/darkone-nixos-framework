# DNF just — checks: dead code, lint, unit tests, flake.

# Run all checks and tests (useful before deployment)
[group('check')]
check:
	#!/usr/bin/env bash
	set -euo pipefail
	cd {{workDir}} && just check-code

	# Framework unit tests on a checkout only: a store symlink is read-only and
	# was tested before its release.
	if [ "{{dnfCheckout}}" = "true" ] ;then
		just --justfile {{dnfDir}}/Justfile unit-tests | grep -v '✅'
	fi
	cd {{workDir}} && just check-flake

# Statix check + recursive deadnix on full nix files + shellcheck
[group('check')]
check-code:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Dead code detection (deadnix)..." "CHECK"
	find . -name "*.nix" -exec deadnix -eq {} \;
	just _log "Checking nix configuration (statix)..." "CHECK"
	statix check .

	# Tracked scripts only: the `dnf/` store symlink, `node_modules/` or a
	# stray download are not ours to lint. A `dnf/` checkout is a repo apart.
	just _log "Checking shell scripts (shellcheck)..." "CHECK"
	repos=(.)
	if [ "{{isCodev}}" = "true" ]; then
		repos+=(dnf)
	fi
	for repo in "${repos[@]}"; do
		if git -C "$repo" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
			(cd "$repo" && git ls-files -z '*.sh' | xargs -0 -r shellcheck)
		fi
	done

# Check the main flake. Filter benign "unknown flake output" warnings for the
# DNF non-standard outputs (colmena, colmenaHive, homeManagerModules,
# libTests, mkNodes, secretsPlan, hostSecretsPlans); any *other* unknown
# output stays visible.
# sed (vs. grep -v) always exits 0, which keeps pipefail honest about nix's
# real exit status.
#
# Check the main flake (nix flake check)
[group('check')]
check-flake:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Checking flake configuration (wait)..." "CHECK"
	{{nix}} flake check --quiet 2>&1 \
	  | sed -E "/^warning: unknown flake output '(colmena|colmenaHive|homeManagerModules|libTests|mkNodes|secretsPlan|hostSecretsPlans|version)'\$/d"
