# Darkone framework — shared Justfile recipes
# darkone@darkone.yt
#
# This Justfile is imported by both the consumer root Justfile (via project.just)
# and the framework dnf/Justfile (directly). All path-derived variables use
# `justfile_directory()` so they resolve to the *root* justfile's directory —
# i.e. the consumer's workspace when imported via the root Justfile, or `dnf/`
# when invoked standalone for framework-only checks (unit-tests, check-flake, ...).

# `set shell` applies per-line to non-shebang recipes (each line is a separate
# `bash -euo pipefail -c "..."` invocation). Shebang recipes (`#!/usr/bin/env bash`)
# bypass this entirely and run as plain scripts — they need their own `set -euo pipefail`.
set shell := ["bash", "-euo", "pipefail", "-c"]

workDir := justfile_directory()
dnfDir := source_directory() + '/../..'
secretsDir := workDir + '/usr/secrets'
sopsSecretsFile := secretsDir + '/secrets.yaml'
sopsInfraTargetDir := '/etc/sops/age'

# Infra age key now lives outside the repo, under /etc/sops/age (restricted),
# instead of usr/secrets. It is the file sops-nix reads on every host and the
# file pushed by `push-key`. During a key rotation it transiently holds BOTH
# the new and the old identity (concatenated), with the two single keys kept
# alongside as `.cur` / `.old` sidecars (rotation-only).
sopsInfraKeyFile := sopsInfraTargetDir + '/infra.key'
sopsInfraCurKeyFile := sopsInfraTargetDir + '/infra.key.cur'
sopsInfraOldKeyFile := sopsInfraTargetDir + '/infra.key.old'
fixturesDir := dnfDir + '/tests/fixtures'
nix := 'nix --extra-experimental-features "nix-command flakes"'
logPrefix := '[ {{CYAN}}DNF{{NORMAL}} ] '

# Repos to iterate in git commands: dnf, doc, all src/* dirs, then .
repos := `for d in src/*/; do [ -d "$d/.git" ] && echo "${d%/}"; done; printf '%s\n' dnf doc .`

alias c := clean
alias d := develop
alias g := git
alias amend := git-amend
alias commit := git-commit
alias diff := git-diff
alias status := git-status
alias push := git-push
alias pull := git-pull

#==============================================================================
# Functions
#==============================================================================

# Log
_log msg context="":
	#!/usr/bin/env bash
	if [ -z "$QUIET" ] ;then
		if [ "{{context}}" == "" ] ;then
			echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{msg}}"
		else
			echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{BOLD + MAGENTA}}{{context}}{{NORMAL}} • {{msg}}"
		fi
	fi

# Error
_err msg:
	@echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{BOLD + RED}}ERR{{NORMAL}} • {{msg}}" >&2

# Warn
_warn msg:
	@echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{BOLD + YELLOW}}WRN{{NORMAL}} • {{msg}}" >&2

# Info
_info msg context="INF":
	@echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{BOLD + GREEN}}{{context}}{{NORMAL}} • {{msg}}" >&2

# Done
_done:
	@just _log "{{GREEN}}Done{{NORMAL}}"

# Fail
_fail msg:
	@just _err "{{msg}}"
	@exit 1

# Check that the infra age key is present on this host. Called by admin
# recipes that have already auto-switched to the `nix` user, so the
# previous `USER == nix` guard is now redundant (only the file check remains).
_check_infra_admin:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f {{sopsInfraKeyFile}} ] ;then
		just _err "Infra private key not found, you must do that from the admin host."
		just _fail "If you are on the admin host, type 'just install-admin-host' before."
	fi

_fix_fs_permissions:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Fixing filesystem permissions..." "FS"
	sudo chown -R --reference=. .
	sudo chmod 644 {{sopsSecretsFile}}

	# Infra key(s) live under /etc/sops/age, owned by the nix deploy user so
	# the admin tooling can read them (root/sops-nix reads them regardless).
	# The .cur/.old sidecars exist only mid-rotation.
	for keyfile in {{sopsInfraKeyFile}} {{sopsInfraCurKeyFile}} {{sopsInfraOldKeyFile}} ;do
		if [ -f "$keyfile" ] ;then
			sudo chown nix "$keyfile"
			sudo chmod 600 "$keyfile"
		fi
	done

_sops_before_edit:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Switch permissions for secrets..." "SOPS"
	if [ -d {{secretsDir}} ] ;then
		sudo chown -R nix {{secretsDir}}
	fi
	if [ -f {{sopsSecretsFile}} ] ;then
		sudo chmod 600 {{sopsSecretsFile}}
	fi

#==============================================================================
# Check
#==============================================================================

# Recursive deadnix on nix files
[group('check')]
check:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Full checking..." "DEADNIX"
	find . -name "*.nix" -exec deadnix -eq {} \;

# Check the main flake. Filter benign "unknown flake output" warnings for the
# DNF non-standard outputs (colmena, colmenaHive, homeManagerModules,
# libTests); any *other* unknown output stays visible. sed (vs. grep -v)
# always exits 0, which keeps pipefail honest about nix's real exit status.
[group('check')]
check-flake:
	{{nix}} flake check --all-systems --quiet 2>&1 \
	  | sed -E "/^warning: unknown flake output '(colmena|colmenaHive|homeManagerModules|libTests)'\$/d"

# Check with statix
[group('check')]
check-statix:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Checking nix configuration..." "STATIX"
	statix check .

#==============================================================================
# Development
#==============================================================================

# format: fix + check + generate + format
[group('dev')]
clean: fix check generate format _fix_fs_permissions

# treefmt orchestrates formatters in parallel (via treefmt.toml)
[group('dev')]
format:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Full formatting..." "TREEFMT"
	treefmt --config-file {{dnfDir}}/assets/treefmt.toml --no-cache --quiet

# Fix with statix
[group('dev')]
fix:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Full fixing..." "STATIX"
	statix fix .

#==============================================================================
# Generators
#==============================================================================

# Update the nix generated files
[group('dev')]
generate: \
	(_gen-default "dnf/modules") \
	(_gen-default "usr/modules") \
	(_gen-default "dnf/home/modules") \
	(_gen-default "usr/home/modules") \
	(_gen "users") \
	(_gen "hosts") \
	(_gen "network") \
	(_gen "disko")

# Generator of default.nix files
_gen-default dir:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -d "{{dir}}" ] ;then
		just _info "Skipping unknown directory {{dir}}..."
	else
		just _log "{{dir}} ➜ default.nix..." "GENERATOR"
		cd {{dir}}
		{
			echo "# DO NOT EDIT, this is a generated file."
			echo
			echo "{ imports = ["
			find . -name "*.nix" | sort | grep -v default.nix || true
			echo "];}"
		} > default.nix
		nixfmt -sv default.nix
	fi

# Generate var/generated/*.nix files
#
# Two execution paths, picked at runtime:
#  - Co-dev (sources on disk + cargo available): `cargo run` keeps the fast
#    incremental compile loop used while hacking on the generator.
#  - Release (no local checkout): fall back to the `dnf-generator` binary
#    provided by the framework devShell (`nix develop github:.../#default`).
_gen what:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "{{what}} file(s)..." "GENERATOR"

	# Keep CWD on the workspace root so the generator's default `--workdir`
	# resolves to `{{workDir}}` (and reads `etc/config.yaml` there).
	if [ -f src/generator/Cargo.toml ] && command -v cargo >/dev/null 2>&1; then
		cargo run --quiet --manifest-path src/generator/Cargo.toml -- {{what}} > /dev/null
	elif command -v dnf-generator >/dev/null 2>&1; then
		dnf-generator {{what}} > /dev/null
	else
		just _fail "Generator unavailable: enter 'nix develop github:darkone-linux/darkone-nixos-framework' or provide src/generator/"
	fi

# Launch a "nix develop" with zsh (dev env)
[group('dev')]
develop:
	@just _log "Launching nix develop with zsh..."
	{{nix}} develop -c zsh

#==============================================================================
# Installation (framework-only)
#==============================================================================

# Build DNF iso image
[group('install')]
build-iso arch="x86_64-linux":
	@just _log "Building local DNF ISO image..."
	sudo -i -u nix {{nix}} build .#nixosConfigurations.iso-{{arch}}.config.system.build.isoImage

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

			# Record the lock bump: nothing staged => already coherent; same
			# message => fold into the shared commit; different message => a
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
