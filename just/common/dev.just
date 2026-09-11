# DNF just — development: clean, format, generate, dev shell.

alias c := clean
alias d := develop

# Statix fix, code check, generate, format (run before committing)
[group('dev')]
clean: _statix check-code generate format _fix_fs_permissions

# treefmt orchestrates formatters in parallel (via treefmt.toml)
[group('dev')]
format:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Full formatting..." "TREEFMT"
	treefmt --config-file {{dnfDir}}/assets/treefmt.toml --no-cache --quiet

	# A `dnf/` symlink points into the nix store (read-only): only a real
	# co-development checkout is formatted here.
	if [ "{{isCodev}}" = "true" ] ;then
		just _log "Formatting also dnf..." "TREEFMT"
		cd dnf && treefmt --config-file {{dnfDir}}/assets/treefmt.toml --no-cache --quiet
	fi

# Fix with statix
[group('dev')]
_statix:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Full fixing..." "STATIX"
	statix fix .

# Consumer project: framework and local `default.nix` import lists, then the
# Rust-generated `var/generated/*.nix`. Framework alone: its own import lists.
#
# Update the nix generated files.
[group('dev')]
generate:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ "{{isProject}}" = "true" ]; then
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
	if [ ! -d "{{dir}}" ] || [ ! -w "{{dir}}" ] ;then

		# Unknown (consumer without that overlay) or read-only (framework tree
		# symlinked from the nix store): nothing to generate there.
		just _info "Skipping {{dir}} (absent or read-only)..."
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
