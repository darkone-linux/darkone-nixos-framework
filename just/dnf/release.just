# DNF just — framework release: version, changelog, tag.
#
# The ecosystem-wide train lives in `codev/release.just`. dnf-doc and
# dnf-generator call the same `just/scripts/bump.sh` through their own `bump`.

# Bump VERSION, prepend the CHANGELOG entry, commit and tag (no push)
[group('release')]
bump level="auto" *args:
	bash {{ scriptsDir }}/bump.sh \
	    --repo {{ dnfDir }} --config {{ cliffConfig }} --level {{ level }} {{ args }}

# Preview the entry the next release would carry — writes nothing
[group('release')]
changelog:
	@git-cliff --config {{ cliffConfig }} --unreleased --bump 2>/dev/null

# Framework version, revision and the generator release it pins
[group('release')]
version:
	#!/usr/bin/env bash
	set -euo pipefail
	cd {{ dnfDir }}
	just _log "release ....... $(cat VERSION)" "VER"
	just _log "revision ...... $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (dirty)')" "VER"
	just _log "last tag ...... $(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo 'none')" "VER"

	# The lock is the contract: whatever the URL says, this is what a consumer
	# pinning this framework actually gets.
	gen=$(jq -r '.nodes["dnf-generator"].original.ref // .nodes["dnf-generator"].locked.rev[0:7]' flake.lock)
	just _log "dnf-generator . ${gen}" "VER"
