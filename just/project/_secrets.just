# DNF just — private secrets helpers: infra key guard, sops permissions and files.

# Guard for recipes that need the infra age key: only the admin host holds it.
_check_infra_admin:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ ! -f {{sopsInfraKeyFile}} ] ;then
		just _err "Infra private key not found, you must do that from the admin host."
		just _fail "If you are on the admin host, run 'just configure-admin-host' first."
	fi

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

# Generate every internal secret the fleet declares (idempotent, silent when
# there is nothing to create).
#
# The list is NOT maintained here: `<workDir>#secretsPlan` collects the
# `sops.secrets` of every host and classifies each entry (dnf/lib/secrets.nix),
# so enabling a service is enough to bring its secrets along. Only what DNF can
# invent on its own is created; human, hardware and third-party secrets stay
# manual (`just sops`, `just passwd`, `just luks`, `just yubikey`,
# `just configure-alert-bot`). An existing entry is never overwritten.
_gen-secrets:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just _gen-secrets
	just _sops_before_edit
	n=$(WORKDIR="{{workDir}}" SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
		bash {{scriptsDir}}/generate-secrets.sh)
	case "$n" in
		skip) ;;
		0) just _info "Secrets already generated." "SOPS" ;;
		*) just _log "$n secret(s) generated." "SOPS" ;;
	esac

# (Re)generate usr/secrets/.sops.yaml from the current recipients: the admin
# SSH-derived age key plus the infra key(s). During a rotation both the new
# (.cur) and previous (.old) infra keys are recipients; otherwise just the
# single operational infra key.
_regen-sops-yaml:
	#!/usr/bin/env bash
	set -euo pipefail

	# Admin recipient, derived straight from the SSH public key (ssh-to-age on
	# the pub key yields a single age1... line, without parsing keys.txt which
	# some ssh-to-age versions don't expose as a native AGE-SECRET-KEY-1).
	ADM_PUB=$(ssh-to-age -i "$HOME/.ssh/id_ed25519.pub")
	recipients=("$ADM_PUB")

	# Infra recipients. age-keygen -y is only ever run on single-identity files.
	if [ -f {{sopsInfraCurKeyFile}} ] && [ -f {{sopsInfraOldKeyFile}} ] ;then
		recipients+=("$(age-keygen -y {{sopsInfraCurKeyFile}})")
		recipients+=("$(age-keygen -y {{sopsInfraOldKeyFile}})")
	else
		recipients+=("$(age-keygen -y {{sopsInfraKeyFile}})")
	fi
	just _sops_before_edit
	{
		echo "creation_rules:"
		echo "  - path_regex: \"[^/]+\\\\.yaml\$\""
		echo "    key_groups:"
		echo "    - age:"
		for r in "${recipients[@]}" ;do
			echo "      - ${r}"
		done
	} > {{sopsYamlFile}}
