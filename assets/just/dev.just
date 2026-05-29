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
