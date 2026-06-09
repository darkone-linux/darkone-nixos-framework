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

alias c := clean
alias d := develop

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

	# Consumer project only: secrets file lives under usr/secrets/ and needs
	# world-read for the nix build sandbox. In framework-standalone mode
	# there is no usr/ tree, so skip.
	if [ -f "{{workDir}}/etc/config.yaml" ]; then
		sudo chmod 644 {{sopsSecretsFile}}
	fi

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
	{{nix}} flake check --quiet 2>&1 \
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
	if [ -d dnf ] ;then
		just _log "Formatting also dnf..." "TREEFMT"
		cd dnf && treefmt --config-file {{dnfDir}}/assets/treefmt.toml --no-cache --quiet
	fi

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

# Update the nix generated files.
#
# Detects the running context:
#   - Consumer project (workDir has etc/config.yaml): full generation including
#     Rust-generated files (var/generated/*.nix) and consumer-side paths.
#   - Framework standalone (workDir is dnf/ itself): only framework module
#     default.nix files, no Rust generator (no config.yaml to consume).
[group('dev')]
generate:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ -f "{{workDir}}/etc/config.yaml" ]; then
		just _gen-default "dnf/modules"
		just _gen-default "usr/modules"
		just _gen-default "dnf/home/modules"
		just _gen-default "usr/home/modules"
		just _gen "users"
		just _gen "hosts"
		just _gen "network"
		just _gen "disko"
	else
		just _gen-default "modules"
		just _gen-default "home/modules"
	fi

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


