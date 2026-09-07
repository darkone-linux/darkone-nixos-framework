# Darkone framework — release recipes (framework repo)
#
# Imported by dnf/Justfile after common.just, whose `assetsDir` / `dnfDir` these
# recipes reuse. The ecosystem-wide train lives in dev.just, at the root of a
# co-development workspace; here we only cut the framework's own release.
#
# dnf-doc and dnf-generator are separate repos with their own Justfile: they
# call the same assets/scripts/just-bump.sh through their own `bump` recipe.

cliffConfig := assetsDir + '/release/cliff.toml'

#==============================================================================
# Release
#==============================================================================

# Bump VERSION, prepend the CHANGELOG entry, commit and tag (no push)
[group('release')]
bump level="auto" *args:
	bash {{ assetsDir }}/scripts/just-bump.sh \
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
