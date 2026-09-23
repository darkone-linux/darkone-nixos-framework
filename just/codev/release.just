# DNF just — ecosystem release train: generator, fleet-update, framework, doc,
# templates.

bumpScript := scriptsDir / 'bump.sh'

# Current version, last tag and framework pins, for every repo of the workspace
[group('release')]
versions:
	#!/usr/bin/env bash
	set -euo pipefail
	printf '%-20s %-10s %-10s %s\n' "REPO" "VERSION" "LAST TAG" "BRANCH"
	while IFS= read -r repo; do
		[ -z "$repo" ] && continue
		tag=$(git -C "$repo" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo "-")
		if [ -f "$repo/VERSION" ]; then
			version=$(tr -d '[:space:]' < "$repo/VERSION")
		elif [ -f "$repo/Cargo.toml" ]; then
			version=$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$repo/Cargo.toml" | head -n1)
		elif [ -f "$repo/package.json" ]; then
			version=$(jq -r '.version' "$repo/package.json")
		elif [ "$tag" != "-" ] && [ "$repo" != "." ]; then

			# Templates: the tag is the version.
			version="${tag#v}"
		else
			version="-"
		fi
		branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")
		printf '%-20s %-10s %-10s %s\n' "$repo" "$version" "$tag" "$branch"
	done <<< "{{repos}}"

	# What a consumer pinning this framework actually gets, whatever the URL says.
	# printf, not `just _info`: a nested recipe writes to stderr and would land
	# out of order with the table above.
	gen=$(jq -r '.nodes["dnf-generator"].original.ref // "(floating branch)"' dnf/flake.lock)
	printf '\ndnf pins dnf-generator: %s\n' "$gen"
	fu=$(sed -n 's/^  version = "\(.*\)";$/\1/p' dnf/pkgs/fleet-update/package.nix)
	printf 'dnf pins fleet-update:  %s\n' "$fu"

# Release the whole ecosystem: generator, fleet-update, framework, doc, templates
[group('release')]
release level="auto":
	#!/usr/bin/env bash
	set -euo pipefail

	gen=src/generator
	fu=src/dnf-fleet-update
	templates=(src/dnf-boilerplate src/dnf-example)
	fuPkg=dnf/pkgs/fleet-update/package.nix
	docJust="just --justfile doc/Justfile --working-directory doc"

	lastTag() { git -C "$1" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true; }

	# A repo is due when it was never tagged or moved since its last tag.
	isDue() {
		local tag
		tag=$(lastTag "$1")
		[ -z "$tag" ] || [ -n "$(git -C "$1" rev-list "$tag"..HEAD)" ]
	}
	next() { bash {{bumpScript}} --repo "$1" --config {{cliffConfig}} --next "${@:2}"; }
	bump() { bash {{bumpScript}} --repo "$1" --config {{cliffConfig}} --yes "${@:2}"; }

	# The branch and this release's tag only: `--tags` would publish every
	# local tag (backups, experiments) too.
	publish() { git -C "$1" push --atomic origin main "refs/tags/$2"; }

	#---------------------------------------------------------------------------
	# Preflight — cheap failures before the long gates
	#---------------------------------------------------------------------------

	# Co-dev only: the train needs every repo as a working tree, not as a
	# pinned flake input.
	for repo in dnf doc "$gen" "$fu" "${templates[@]}"; do
		[ -d "$repo/.git" ] || just _fail "Missing checkout: $repo/ — the train needs the full workspace."
	done
	for bin in git-cliff jq python3 nix-update; do
		command -v "$bin" > /dev/null || just _fail "Missing tool: $bin — run 'just develop' first."
	done
	for repo in dnf doc "$gen" "$fu" "${templates[@]}"; do
		[ -z "$(git -C "$repo" status --porcelain)" ] || just _fail "$repo/: dirty tree — commit or stash first."
		[ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = main ] || just _fail "$repo/: not on main."

		# One SSH round trip per repo: `main` and the last release tag together.
		# No fetch: a diverging old tag would fail it, and it adds a connection.
		just _log "Checking origin of $repo/..." "REL"
		tag=$(lastTag "$repo")
		refs=$(git -C "$repo" ls-remote origin refs/heads/main ${tag:+"refs/tags/$tag"}) ||
			just _fail "$repo/: origin unreachable — check SSH access (ssh -T git@github.com)."

		# Behind or diverged: origin's main is unknown locally or not an ancestor.
		remoteMain=$(awk '$2 == "refs/heads/main" { print $1 }' <<< "$refs")
		git -C "$repo" merge-base --is-ancestor "$remoteMain" HEAD 2>/dev/null ||
			just _fail "$repo/: behind origin/main — pull first."

		# `isDue` trusts the local tag: it must be the published one. A local-only
		# tag is a train stopped between tag and push.
		[ -n "$tag" ] || continue
		remoteTag=$(awk -v r="refs/tags/$tag" '$2 == r { print $1 }' <<< "$refs")
		[ -n "$remoteTag" ] || just _fail "$repo/: $tag is local only — push it: git -C $repo push --atomic origin main refs/tags/$tag"
		[ "$remoteTag" = "$(git -C "$repo" rev-parse "refs/tags/$tag")" ] || just _fail "$repo/: $tag differs from origin — realign the local tag first."
	done

	#---------------------------------------------------------------------------
	# Plan — what moved, what it drags along, at which version
	#---------------------------------------------------------------------------

	# A dependency release forces a framework release: the pin is a commit.
	genDue=false; isDue "$gen" && genDue=true
	fuDue=false; isDue "$fu" && fuDue=true
	genPinned=$(sed -n 's|^    dnf-generator.url = "github:darkone-linux/dnf-generator/\(v[^"]*\)";$|\1|p' dnf/flake.nix)
	fuPinned=v$(sed -n 's/^  version = "\(.*\)";$/\1/p' "$fuPkg")
	dnfDue=false
	if isDue dnf || $genDue || $fuDue || [ "$genPinned" != "$(lastTag "$gen")" ] || [ "$fuPinned" != "$(lastTag "$fu")" ]; then
		dnfDue=true
	fi

	$genDue && genNext=$(next "$gen")
	$fuDue && fuNext=$(next "$fu")
	dnfCurrent=$(tr -d '[:space:]' < dnf/VERSION)
	dnfTarget=$dnfCurrent
	$dnfDue && dnfTarget=$(next dnf --level "{{level}}")

	# The doc also moves when the framework does: its reference is regenerated.
	docDue=false
	if isDue doc || $dnfDue; then
		docDue=true
		docNext=$(next doc --line "${dnfTarget%.*}")
	fi

	# Templates mirror the framework tag: they catch up on it, never lead it.
	dueTemplates=()
	for repo in "${templates[@]}"; do
		if [ "$(lastTag "$repo")" != "v$dnfTarget" ]; then
			dueTemplates+=("$repo")
		elif isDue "$repo"; then
			just _warn "$repo/ moved since v$dnfTarget — shipped with the next framework release."
		fi
	done

	if ! $genDue && ! $fuDue && ! $dnfDue && ! $docDue && [ ${#dueTemplates[@]} -eq 0 ]; then
		just _info "Nothing to release: every repo is at its last tag." "REL"
		exit 0
	fi

	printf '\n%-22s %-10s %s\n' "REPO" "CURRENT" "NEXT"
	row() { local t; t=$(lastTag "$1"); printf '%-22s %-10s %s\n' "$1" "${t:--}" "$2"; }
	row "$gen" "$($genDue && echo "v$genNext" || echo '(unchanged)')"
	row "$fu" "$($fuDue && echo "v$fuNext" || echo '(unchanged)')"
	row dnf "$($dnfDue && echo "v$dnfTarget" || echo '(unchanged)')"
	row doc "$($docDue && echo "v$docNext (if anything to regenerate or ship)" || echo '(unchanged)')"
	for repo in "${templates[@]}"; do
		if [[ " ${dueTemplates[*]} " == *" $repo "* ]]; then row "$repo" "v$dnfTarget"; else row "$repo" '(unchanged)'; fi
	done

	# Previews of the entries git-cliff will write. Dependency pins are not
	# committed yet: they join the framework entry at release time.
	preview() {
		printf '\n\033[1m%s\033[0m' "$1"
		git-cliff --config {{cliffConfig}} --repository "$1" --unreleased --tag "v$2" 2>/dev/null
	}
	$genDue && preview "$gen" "$genNext"
	$fuDue && preview "$fu" "$fuNext"
	$dnfDue && preview dnf "$dnfTarget"
	$docDue && preview doc "$docNext"
	echo
	read -r -p "Run the release train? [y/N] " answer
	[ "${answer,,}" = y ] || just _fail "Aborted — nothing written."

	#---------------------------------------------------------------------------
	# 1. Global gate
	#---------------------------------------------------------------------------

	just _log "Quality gate (code, unit tests)..." "REL"
	just check

	#---------------------------------------------------------------------------
	# 2. Generator — owns the etc/config.yaml schema, so it goes first
	#---------------------------------------------------------------------------

	if $genDue; then
		just _log "Releasing dnf-generator v$genNext..." "REL"
		just gen-test
		bump "$gen" --level "$genNext"
		publish "$gen" "v$genNext"
	fi

	# Pinned in `flake.nix` too, not only in the lock: the framework ↔ generator
	# contract has to be visible in a diff. Anchored on the declaration's
	# indentation: the comment block above it documents the form.
	genTag=$(lastTag "$gen")
	if [ "$genPinned" != "$genTag" ]; then
		just _log "Pinning dnf-generator $genTag..." "REL"
		sed -i "s|^\(    dnf-generator.url = \)\"github:darkone-linux/dnf-generator[^\"]*\";|\1\"github:darkone-linux/dnf-generator/$genTag\";|" dnf/flake.nix
		(cd dnf && {{nix}} flake update dnf-generator)
		git -C dnf add flake.nix flake.lock
		git -C dnf commit -q -m "chore(deps): dnf-generator $genTag"
	fi

	#---------------------------------------------------------------------------
	# 3. fleet-update — packaged by the framework, so released before it
	#---------------------------------------------------------------------------

	if $fuDue; then
		just _log "Releasing dnf-fleet-update v$fuNext..." "REL"

		# Its CI gates with its own toolchain, audit included: a red
		# `release.yml` after the tag push means a tag without a release.
		fuGate() {
			nix develop "./$fu" --command \
				just --justfile "$fu/Justfile" --working-directory "$fu" "$1"
		}
		fuGate ci
		fuGate audit
		bump "$fu" --level "$fuNext"
		publish "$fu" "v$fuNext"
	fi

	fuTag=$(lastTag "$fu")
	if [ "$fuPinned" != "$fuTag" ]; then
		just _log "Pinning dnf-fleet-update $fuTag..." "REL"
		just pkg-update fleet-update "${fuTag#v}"
		(cd dnf && {{nix}} build --no-link .#fleet-update)
		git -C dnf add pkgs/fleet-update
		git -C dnf commit -q -m "chore(deps): fleet-update $fuTag"
	fi

	#---------------------------------------------------------------------------
	# 4. Framework — gated on the pins it ships with
	#---------------------------------------------------------------------------

	if $dnfDue; then

		# Simulations run on the locked dependencies, hence after the pins. They
		# are NOT in CI: a red scenario has to stop the release here or nowhere.
		just _log "Simulations against the pinned dependencies..." "REL"
		just simulate all
		just _log "Releasing the framework v$dnfTarget..." "REL"
		bump dnf --level "$dnfTarget"
		publish dnf "v$dnfTarget"
	fi

	#---------------------------------------------------------------------------
	# 5. Documentation — reference regenerated from the framework it documents
	#---------------------------------------------------------------------------

	if $docDue; then
		just _log "Regenerating the documentation..." "REL"
		$docJust codegen
		$docJust translate
		$docJust clean
		if [ -n "$(git -C doc status --porcelain)" ]; then
			git -C doc add -A
			git -C doc commit -q -m "docs(ref): regenerate for dnf v$dnfTarget"
		fi

		# Same framework, nothing regenerated, nothing written: no release. Built
		# before the tag: a broken link must not ship.
		if isDue doc; then
			$docJust build
			bump doc --line "${dnfTarget%.*}"
			docVersion=$(jq -r .version doc/package.json)
			publish doc "v$docVersion"

			# GitHub Pages repo: a separate checkout under doc/, unversioned.
			$docJust deploy "Release v$docVersion"
		else
			just _info "Documentation unchanged — no release." "REL"
		fi
	fi

	#---------------------------------------------------------------------------
	# 6. Consumer templates — only the pin; the committed lock is the point
	#---------------------------------------------------------------------------

	for repo in "${dueTemplates[@]}"; do
		just _log "Aligning $repo on v$dnfTarget..." "REL"
		sed -i "s|^\(    dnf.url = \)\"github:darkone-linux/darkone-nixos-framework[^\"]*\";|\1\"github:darkone-linux/darkone-nixos-framework/v$dnfTarget\";|" "$repo/flake.nix"
		(cd "$repo" && {{nix}} flake update dnf && {{nix}} flake check --no-build)
		git -C "$repo" add flake.nix flake.lock
		git -C "$repo" diff --cached --quiet ||
			git -C "$repo" commit -q -m "chore(deps): dnf v$dnfTarget"
		bump "$repo" --level "$dnfTarget"
		publish "$repo" "v$dnfTarget"
	done

	#---------------------------------------------------------------------------
	# 7. Workspace root — never tagged, relocked on the released framework
	#---------------------------------------------------------------------------

	# Unconditional: a train resumed after a failure still owes this step.
	just update-dnf
	if ! git diff --quiet -- flake.lock; then
		git add flake.lock
		git commit -q -m "chore(release): track dnf v$dnfTarget" -- flake.lock
	fi

	just _log "Train done — GitHub releases are cut by each release.yml." "REL"
	just versions
