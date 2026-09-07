# Darkone framework — developer-only Justfile recipes
# darkone@darkone.yt
#
# Imported by the consumer root Justfile alongside project.just (which brings
# in common.just). Provides git multi-repo helpers and generator build commands
# used only during framework/consumer co-development.
#
# In consumer templates (dnf-boilerplate, dnf-example) this import is commented
# out — uncomment only when developing the framework or its sub-projects.

# Repos to iterate in git commands: dnf, doc, all src/* dirs, then .
repos := `for d in src/*/; do [ -d "$d/.git" ] && echo "${d%/}"; done; printf '%s\n' dnf doc .`

alias g := git
alias amend := git-amend
alias commit := git-commit
alias diff := git-diff
alias status := git-status
alias push := git-push
alias pull := git-pull

#==============================================================================
# Sub-projects
#==============================================================================

# Build the Rust generator
[group('src')]
gen-build:
	just --justfile src/generator/Justfile build

# Run Rust generator unit tests
[group('src')]
gen-test:
	just --justfile src/generator/Justfile test

#==============================================================================
# Dual-repo git helpers (arthur-network + framework)
#==============================================================================

# Add and commit changes in several projects with the same message
[group('dev')]
git-commit msg on="all":
	#!/usr/bin/env bash
	set -euo pipefail

	# Commit all projects, but keep the root (.) for last: it must capture the
	# refreshed dnf lock, so it is committed only after update-dnf below.
	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			[ "$repo" == "." ] && continue
			just git-commit "{{msg}}" "$repo"
		done <<< "{{repos}}"

		# Dev mode only: sync the root flake.lock onto the freshly committed dnf
		# HEAD so the upcoming root commit pins a coherent framework revision.
		if [ -d "{{workDir}}/dnf/.git" ]; then
			just update-dnf
		fi
		just git-commit "{{msg}}" "."
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi
		git -C {{on}} add -A
		if git -C {{on}} diff --cached --quiet ;then
			just _info "Nothing to commit on {{on}}/" "GIT"
		else

			# Re-committing with the previous message means amend, not a new
			# commit (decided per-project, keeps the recipe idempotent).
			last=$(git -C {{on}} log -1 --format=%s 2>/dev/null || echo "")
			if [ "{{msg}}" == "$last" ]; then
				just _log "Amending {{on}}/ (same message)" "GIT"
				git -C {{on}} commit --amend --no-edit > /dev/null
			else
				just _log "Committing on {{on}}/" "GIT"
				git -C {{on}} commit -m "{{msg}}" > /dev/null
			fi
		fi
	fi

# Amend last commit in several projects with current changes (--no-edit)
[group('dev')]
git-amend on="all":
	#!/usr/bin/env bash
	set -euo pipefail

	# Amend all projects (root included): fold each tree's working changes into
	# its last commit, keeping its message.
	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			just git-amend "$repo"
		done <<< "{{repos}}"

		# Dev mode only: refresh the root lock onto the amended dnf HEAD, then
		# keep the root coherent with dnf. The pass above already committed the
		# root's own changes, so only the flake.lock delta remains here.
		if [ -d "{{workDir}}/dnf/.git" ]; then
			just update-dnf
			dnf_msg=$(git -C dnf log -1 --format=%s 2>/dev/null || echo "")
			root_msg=$(git -C . log -1 --format=%s 2>/dev/null || echo "")

			# Record the lock bump: nothing staged ⇒ already coherent; same
			# message ⇒ fold into the shared commit; different message ⇒ a
			# dedicated commit pins dnf so a root revert stays tied to a
			# compatible framework revision.
			git -C . add -A
			if git -C . diff --cached --quiet ;then
				just _info "Lock already coherent, nothing to align on ./" "GIT"
			elif [ "$dnf_msg" == "$root_msg" ]; then
				just _log "Folding dnf lock bump into ./ (aligned)" "GIT"
				git -C . commit --amend --no-edit --allow-empty > /dev/null
			else
				just _log "New ./ commit to pin dnf: $dnf_msg" "GIT"
				git -C . commit -m "$dnf_msg" > /dev/null
			fi
		fi
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi

		# `--allow-empty` keeps the recipe idempotent even when a tree is clean.
		git -C {{on}} add -A
		if ! git -C {{on}} diff --cached --quiet ;then
			just _log "Amending {{on}}/" "GIT"
			git -C {{on}} commit --amend --no-edit --allow-empty > /dev/null
		else
			just _info "Nothing to amend on {{on}}/" "GIT"
		fi
	fi

# Git status for one or all projects
[group('dev')]
git-status on="all":
	just git "status -s" {{on}} "Status of"

# Git diff for one or all projects
[group('dev')]
git-diff on="all":
	just git "diff" {{on}} "Diff of"

# Git push for one or all projects — check ahead before pushing
[group('dev')]
git-push on="all":
	#!/usr/bin/env bash
	set -euo pipefail

	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			just git-push "$repo"
		done <<< "{{repos}}"
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi
		if ! upstream=$(git -C {{on}} rev-parse --abbrev-ref @{u} 2>/dev/null); then
			just _info "No upstream branch — set one with 'git push -u origin HEAD'" "GIT"
		elif [ "$(git -C {{on}} rev-list --count @{u}..HEAD 2>/dev/null || echo 0)" -eq 0 ]; then
			just _info "Nothing to push on {{on}}/" "GIT"
		else
			just _log "Pushing {{on}}/" "GIT"
			git -C {{on}} push
		fi
	fi

# Git pull for one or all projects
[group('dev')]
git-pull on="all":
	just git "pull" {{on}} "Pulling"

# Show last commit log of all projects with aligned formatting
[group('dev')]
git-last-log:
	#!/usr/bin/env bash
	set -euo pipefail

	repos_list=()
	max_len=0
	while IFS= read -r repo; do
		[ -z "$repo" ] && continue
		repos_list+=("$repo")
		len=${#repo}
		[ "$len" -gt "$max_len" ] && max_len=$len
	done <<< "{{repos}}"

	for repo in "${repos_list[@]}"; do
		msg=$(git -C "$repo" log -1 --pretty='%B' 2>/dev/null | head -n 1)
		[ -z "$msg" ] && continue
		dots=$((max_len - ${#repo} + 2))
		pad=$(printf '%*s' "$dots" '' | tr ' ' '.')
		just _log "Last log of $repo/$pad $msg" "GIT"
	done

# Run any git command on all (or a single) project
[group('dev')]
git cmd on="all" label="":
	#!/usr/bin/env bash
	set -euo pipefail

	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			just git "{{cmd}}" "$repo" "{{label}}"
		done <<< "{{repos}}"
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi
		if [ -n "{{label}}" ]; then
			LABEL="{{label}}"
		else
			LABEL="'git {{cmd}}' on"
		fi
		just _log "$LABEL {{on}}/" "GIT"
		git -C {{on}} {{cmd}}
	fi

# Show repositories
[group('dev')]
git-show-repos:
	@echo "{{repos}}"

#==============================================================================
# Ecosystem release train
#==============================================================================

cliffConfig := dnfDir + '/assets/release/cliff.toml'
bumpScript := dnfDir + '/assets/scripts/just-bump.sh'

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
	just check-all
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
