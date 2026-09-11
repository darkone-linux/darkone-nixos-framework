# DNF just — ecosystem release train: generator, framework, doc, templates.

bumpScript := scriptsDir / 'bump.sh'

# Current version, last tag and pinned generator, for every repo of the workspace
[group('release')]
versions:
	#!/usr/bin/env bash
	set -euo pipefail
	printf '%-20s %-10s %-10s %s\n' "REPO" "VERSION" "LAST TAG" "BRANCH"
	while IFS= read -r repo; do
		[ -z "$repo" ] && continue
		if [ -f "$repo/VERSION" ]; then
			version=$(tr -d '[:space:]' < "$repo/VERSION")
		elif [ -f "$repo/Cargo.toml" ]; then
			version=$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$repo/Cargo.toml" | head -n1)
		elif [ -f "$repo/package.json" ]; then
			version=$(jq -r '.version' "$repo/package.json")
		else
			version="-"
		fi
		tag=$(git -C "$repo" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo "-")
		branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")
		printf '%-20s %-10s %-10s %s\n' "$repo" "$version" "$tag" "$branch"
	done <<< "{{repos}}"

	# What a consumer pinning this framework actually gets, whatever the URL says.
	# printf, not `just _info`: a nested recipe writes to stderr and would land
	# out of order with the table above.
	gen=$(jq -r '.nodes["dnf-generator"].original.ref // "(floating branch)"' dnf/flake.lock)
	printf '\ndnf pins dnf-generator: %s\n' "$gen"

# Release the whole ecosystem: generator, framework, doc, boilerplate, example
[group('release')]
release level="auto":
	#!/usr/bin/env bash
	set -euo pipefail

	# Co-dev only: the train needs every repo as a working tree, not as a
	# pinned flake input.
	for repo in dnf doc src/generator src/dnf-boilerplate src/dnf-example; do
		[ -d "$repo/.git" ] || just _fail "Missing checkout: $repo/ — the train needs the full workspace."
	done

	# 1. Quality gate. Simulations are NOT in CI: a red scenario has to stop the
	#    release here or nowhere.
	just _log "Quality gate..." "REL"
	just check
	just gen-test
	(cd dnf && just simulate all)

	# 2. Generator, only if it moved since its last release. It owns the
	#    etc/config.yaml schema, so it is released before what depends on it.
	genTag=$(git -C src/generator describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo "")
	if [ -z "$genTag" ] || [ -n "$(git -C src/generator log --oneline "$genTag"..HEAD 2>/dev/null)" ]; then
		just _log "Releasing dnf-generator..." "REL"
		bash {{bumpScript}} --repo src/generator --config {{cliffConfig}} --level {{level}}
		git -C src/generator push && git -C src/generator push --tags
	else
		just _info "dnf-generator unchanged since $genTag." "REL"
	fi
	genTag=$(git -C src/generator describe --tags --abbrev=0 --match 'v[0-9]*')

	# 3. Pin the generator release into the framework: the framework ↔ generator
	#    contract has to be visible in a diff, not only in the lock.
	just _log "Pinning dnf-generator $genTag..." "REL"

	# Anchored on the declaration's indentation: the comment block above it
	# documents the pinned form and must not be rewritten too.
	sed -i "s|^\(    dnf-generator.url = \)\"github:darkone-linux/dnf-generator[^\"]*\";|\1\"github:darkone-linux/dnf-generator/$genTag\";|" dnf/flake.nix
	(cd dnf && {{nix}} flake update dnf-generator)
	if [ -n "$(git -C dnf status --porcelain)" ]; then
		just git-commit "chore(deps): dnf-generator $genTag" dnf
	fi

	# 4. Framework.
	just _log "Releasing the framework..." "REL"
	bash {{bumpScript}} --repo dnf --config {{cliffConfig}} --level {{level}}
	dnfVersion=$(tr -d '[:space:]' < dnf/VERSION)
	git -C dnf push && git -C dnf push --tags

	# 5. Documentation. The reference section is regenerated from the framework
	#    it documents, committed, and only then tagged: `bump` demands a clean
	#    tree, and the tag must contain the regenerated pages.
	just _log "Releasing the documentation..." "REL"
	docJust="just --justfile doc/Justfile --working-directory doc"
	$docJust codegen
	$docJust translate
	$docJust clean
	if [ -n "$(git -C doc status --porcelain)" ]; then
		just git-commit "docs(ref): regenerate for dnf v$dnfVersion" doc
	fi
	bash {{bumpScript}} --repo doc --config {{cliffConfig}} --level {{level}} --line "${dnfVersion%.*}"
	git -C doc push && git -C doc push --tags

	# Publishes the built site to the GitHub Pages repo, which is a separate
	# checkout under doc/ and carries no version of its own.
	$docJust build
	$docJust deploy "Release v$(jq -r .version doc/package.json)"

	# 6. Consumer templates: they carry no code, only the pin. A committed
	#    flake.lock is the whole point — without it a clone tracks main.
	for repo in src/dnf-boilerplate src/dnf-example; do
		just _log "Aligning $repo on v$dnfVersion..." "REL"
		sed -i "s|^\(    dnf.url = \)\"github:darkone-linux/darkone-nixos-framework[^\"]*\";|\1\"github:darkone-linux/darkone-nixos-framework/v$dnfVersion\";|" "$repo/flake.nix"
		(cd "$repo" && {{nix}} flake update dnf && {{nix}} flake check --no-build)
		git -C "$repo" add -A
		git -C "$repo" commit -m "chore(release): track dnf v$dnfVersion"
		git -C "$repo" tag -a "v$dnfVersion" -m "Tracks darkone-nixos-framework v$dnfVersion"
		git -C "$repo" push && git -C "$repo" push --tags
	done

	just _log "Released v$dnfVersion — GitHub releases are cut by release.yml." "REL"
	just versions
