# DNF just — private helpers shared by every context: logging, file permissions.

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

_fix_fs_permissions:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Fixing filesystem permissions..." "FS"
	sudo chown -R --reference=. .

	# Consumer project only: secrets file lives under usr/secrets/ and needs
	# world-read for the nix build sandbox. Absent in framework-standalone mode,
	# and until `just configure-admin-host` has run on a fresh workspace.
	if [ -f "{{sopsSecretsFile}}" ]; then
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
