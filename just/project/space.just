# DNF just — AI spaces: bootstrap and secrets of isolated hosts.

# An isolated host (`darkone.system.sops.isolated`, default of the `ai-space`
# profile and of microVM guests) decrypts only `usr/secrets/hosts/<host>.yaml`,
# sealed for the admin key and its own host key, never the infra key.
#
# - host key: created on the hypervisor share of a microVM guest (its private
#   half never leaves it), read over ssh from a bare metal host, or from its
#   installer by `just install`, before the build;
# - Matrix bot, last, on a host running openclaw with a network Matrix:
#   `@<host>:<domain>`, display name and avatar of its `identity`
#   (`configure-space-bot.sh`); rerun after an avatar change;
# - idempotent: an existing host key or secret is never replaced; a changed
#   host key re-encrypts the file for the new one.
#
# Initialize an isolated host: host key, own secrets file, internal secrets, bot
[group('space')]
space-init host:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just space-init "{{host}}"
	[[ "{{host}}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || just _fail "Invalid hostname '{{host}}'."
	just _check_infra_admin

	cfg="{{workDir}}#nixosConfigurations.{{host}}.config.darkone.system"
	isolated=$(nix eval --json "$cfg.sops.isolated" 2>/dev/null) \
		|| just _fail "Cannot evaluate {{host}}: declared in etc/config.yaml, 'just generate' run?"
	[ "$isolated" = "true" ] || just _fail "{{host}} is not isolated: its secrets live in secrets.yaml."
	hypervisor=$(nix eval --json "$cfg.microvm.hypervisor" | jq -r '. // empty')

	# The guest reads its key on `/persist`, a share of the hypervisor.
	if [ -n "$hypervisor" ] ;then
		dir="$(nix eval --raw "$cfg.microvm.stateDir")/{{host}}/persist/ssh"
		key="$dir/ssh_host_ed25519_key"
		t=$(just _resolve "$hypervisor" auto)
		just _log "Host key of {{host}} on $hypervisor ($key)..." "SPACE"
		ssh nix@"$t" "sudo test -s $key.pub || { sudo install -d -m 700 $dir && sudo ssh-keygen -q -t ed25519 -N '' -C root@{{host}} -f $key; }"
		sshPub=$(ssh nix@"$t" "sudo cat $key.pub")
	else
		t=$(just _resolve "{{host}}" auto)
		just _log "Host key of {{host}} (bare metal)..." "SPACE"

		# `ssh-keyscan`: `--copy-host-keys` leaves the `.pub` files root-only.
		sshPub=$( { ssh-keyscan -T 10 -t ed25519 "$t" 2>/dev/null || true ; } | awk '/^[^#]/ {print $2, $3; exit}')
		[ -n "$sshPub" ] || just _fail "Cannot read the host key of {{host}} ($t)."
	fi
	just _space-seal "{{host}}" "$sshPub"

	# Last: needs MAS on the matrix host, a failure leaves the above done.
	openclaw=$(nix eval --json "{{workDir}}#nixosConfigurations.{{host}}.config.darkone.service.openclaw.enable")
	if [ "$openclaw" = "true" ] ;then
		WORKDIR="{{workDir}}" SPACE_HOST="{{host}}" SOPS_AGE_KEY_FILE={{sopsAdminKeyFile}} \
			bash {{scriptsDir}}/configure-space-bot.sh
	else
		just _info "No openclaw service on {{host}}: no Matrix bot." "SPACE"
	fi
	just _log "Commit usr/secrets/.sops.yaml, usr/secrets/hosts/{{host}}.* and var/generated/spaces/: flakes only see tracked files." "SPACE"

# Seals usr/secrets/hosts/<host>.yaml for the admin key and the host SSH key
# `pubkey`, then fills its internal secrets. Shared by `space-init` (key of the
# running host) and `install` (key of the installer, copied to the disk).
_space-seal host pubkey:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just _space-seal "{{host}}" "{{pubkey}}"
	[ -s {{sopsAdminKeyFile}} ] || just _fail "Admin age key not found ({{sopsAdminKeyFile}}). Run 'just configure-admin-host' first."
	recipient=$(printf '%s\n' "{{pubkey}}" | ssh-to-age)
	pubFile={{secretsDir}}/hosts/{{host}}.pub
	file={{secretsDir}}/hosts/{{host}}.yaml

	# Recipient first: `.sops.yaml` then seals the file for this host only.
	# Permissions restored even when a later step fails.
	just _sops_before_edit
	trap 'just _fix_fs_permissions' EXIT
	mkdir -p {{secretsDir}}/hosts
	previous=$(cat "$pubFile" 2>/dev/null || true)
	printf '%s\n' "$recipient" > "$pubFile"
	just _regen-sops-yaml

	# sops resolves `.sops.yaml` from the current directory.
	cd {{secretsDir}}
	if [ ! -f "$file" ] ;then
		printf '{}\n' > "$file"
		sops -e -i "$file"
		just _log "Secrets file created: usr/secrets/hosts/{{host}}.yaml" "SPACE"
	elif [ "$previous" != "$recipient" ] ;then
		SOPS_AGE_KEY_FILE={{sopsAdminKeyFile}} sops updatekeys -y "$file"
		just _log "Host key changed: secrets re-encrypted." "SPACE"
	fi

	# Last line of defence: a fleet rule matching this file would leak it.
	# Recipients read from the metadata: `sops -d` also tries the admin keys.txt.
	expected=$(printf '%s\n' "$(ssh-to-age -i "$HOME/.ssh/id_ed25519.pub")" "$recipient" | sort)
	actual=$(grep -oE 'recipient: age1[0-9a-z]+' "$file" | cut -d' ' -f2 | sort)
	[ "$actual" = "$expected" ] \
		|| just _fail "$file is not sealed for admin + {{host}} only: check {{sopsYamlFile}} before any commit."

	n=$(WORKDIR="{{workDir}}" SECRETS_FILE="$file" SECRETS_PLAN="hostSecretsPlans.{{host}}" \
		SECRETS_EDIT="just space-sops {{host}}" SOPS_AGE_KEY_FILE={{sopsAdminKeyFile}} \
		bash {{scriptsDir}}/generate-secrets.sh)
	case "$n" in
		skip) ;;
		0) just _info "Secrets already generated." "SPACE" ;;
		*) just _log "$n secret(s) generated." "SPACE" ;;
	esac

# Edit the secrets of an isolated host
[group('space')]
space-sops host:
	#!/usr/bin/env bash
	set -euo pipefail
	file={{secretsDir}}/hosts/{{host}}.yaml
	[ -f "$file" ] || just _fail "No secrets file for {{host}}: run 'just space-init {{host}}' first."
	just _sops_before_edit
	sudo -i -u nix EDITOR=vim sops "$file" || true
	just _fix_fs_permissions
