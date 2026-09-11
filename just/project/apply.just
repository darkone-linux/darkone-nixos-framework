# DNF just — deployment (colmena).

# Central build by default (see `buildOnTarget`): the deployer builds every
# closure once and harmonia shares it across the fleet. Set `buildOnTarget=1`
# to restore per-target builds. Ref: https://nixos.wiki/wiki/Binary_Cache

alias a := apply
alias al := apply-local
alias av := apply-verbose

# Apply configuration using colmena
[group('apply')]
apply on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying nix configuration on {{on}} ({{what}})..."

	# Per-target build only when buildOnTarget is set; central build otherwise.
	bot=""; [ -n "{{buildOnTarget}}" ] && bot="--build-on-target"
	if [ "${USER:-}" = "nix" ] ;then
		colmena apply ${bot} --on "{{on}}" {{what}}
	else
		sudo -i -u nix colmena apply --config "{{workDir}}/flake.nix" ${bot} --on "{{on}}" {{what}}
	fi

# Apply with verbose output and traces
[group('apply')]
apply-verbose on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying (verbose) nix configuration on {{on}} ({{what}})..."

	# Per-target build only when buildOnTarget is set; central build otherwise.
	bot=""; [ -n "{{buildOnTarget}}" ] && bot="--build-on-target"
	if [ "${USER:-}" = "nix" ] ;then
		colmena apply ${bot} --verbose --show-trace --on "{{on}}" {{what}}
	else
		sudo -i -u nix colmena apply --config "{{workDir}}/flake.nix" ${bot} --verbose --show-trace --on "{{on}}" {{what}}
	fi

# Apply the local host configuration
[group('apply')]
apply-local what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying locally ({{what}})..."
	colmena apply-local --sudo {{what}}

# Apply with rebuild silence: flag the target(s) under maintenance so
# Alertmanager inhibits their alerts during the restart, then clear the flag.
# Requires the monitoring alerting layer (dnf-maintenance ships on monitored
# nodes); on a first deploy or a non-monitored host the flag step is a no-op.
#
# Apply with the target's alerts silenced during the rebuild
[group('apply')]
apply-silenced on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	_exec() {
		if [ "${USER:-}" = "nix" ] ;then
			colmena exec --on "{{on}}" "$@"
		else
			sudo -i -u nix colmena exec --config "{{workDir}}/flake.nix" --on "{{on}}" "$@"
		fi
	}
	just _log "Silencing alerts on {{on}}..."
	_exec dnf-maintenance on || just _warn "Could not set maintenance flag (first deploy or alerting disabled)."
	trap '_exec dnf-maintenance off || true' EXIT
	just apply "{{on}}" "{{what}}"
