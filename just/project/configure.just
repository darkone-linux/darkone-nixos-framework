# DNF just — configuration: admin host, new hosts, alert bot.

# Framework installation on local machine (builder / admin)
[group('configure')]
configure-admin-host:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just configure-admin-host
	if [ ! -f "$HOME/.ssh/id_ed25519" ] ;then
		just _log "Creating nix keys..." "SSH"
		ssh-keygen -t ed25519 -N ""
	else
		just _info "Maintenance key already exists." "SSH"
	fi
	if [ ! -f {{secretsGitIgnore}} ] ;then
		just _log "Creating usr/secrets directory + gitignore..." "SOPS"
		sudo mkdir -p {{secretsDir}}
		sudo chown nix {{secretsDir}}
		echo '*.key' > {{secretsGitIgnore}}
	else
		just _info "usr/secrets/.gitignore file already exists." "SOPS"
	fi
	just _sops_before_edit
	if [ ! -f "{{secretsDir}}/nix.pub" ] ;then
		if [ ! -f "$HOME/.ssh/id_ed25519.pub" ] ;then
			just _fail "Nix user public key not found!"
		else
			cp "$HOME/.ssh/id_ed25519.pub" "{{secretsDir}}/nix.pub"
		fi
	else
		just _info "Public key {{secretsDir}}/nix.pub already exists." "SSH"
	fi
	if [ ! -s {{sopsAdminKeyFile}} ] ;then
		just _log "Admin key do not exists or is empty." "SOPS"
		just _log "Admin key file creation from ssh private key..." "SOPS"
		mkdir -p {{sopsAdminKeyDir}}
		ssh-to-age -private-key -i "$HOME/.ssh/id_ed25519" -o {{sopsAdminKeyFile}}
	else
		just _info "Admin key file already exists." "SOPS"
	fi
	if [ ! -f {{sopsInfraKeyFile}} ] ;then
		just _log "Infra private key file generation..." "SOPS"

		# The infra key lives under /etc/sops/age (not in the repo). Own the
		# directory as the nix deploy user so the admin tooling can read/manage
		# the key; sops-nix still reads it as root at activation.
		sudo mkdir -p {{sopsInfraTargetDir}}
		sudo chown nix {{sopsInfraTargetDir}}
		age-keygen -o {{sopsInfraKeyFile}}
		chmod 600 {{sopsInfraKeyFile}}
	else
		just _info "Infra key file already exists." "SOPS"
	fi
	if [ ! -f {{sopsYamlFile}} ] ;then
		just _log ".sops.yaml file generation..." "SOPS"
		just _regen-sops-yaml
	else
		just _info ".sops.yaml file already exists." "SOPS"
	fi
	if [ ! -f {{sopsSecretsFile}} ] ;then
		just _log "We need a default password..." "SOPS"
		just passwd-default
	else
		just _info "Default secret file already exists." "SOPS"
	fi

	# Harmonia binary-cache signing key: when the public key is missing,
	# (re)generate the keypair, store the private key in sops and keep the
	# public key committed (read by nix-cache to trust harmonia-signed paths).
	if [ ! -f "{{secretsDir}}/harmonia.pub" ] ;then
		just _log "Generating Harmonia binary-cache signing key..." "SOPS"
		DOMAIN=$(yq '.network.domain // "harmonia"' {{workDir}}/etc/config.yaml 2>/dev/null || echo "harmonia")
		KEY_NAME="cache.${DOMAIN}-1"
		TMP_DIR=$(mktemp -d)
		nix-store --generate-binary-cache-key "$KEY_NAME" "$TMP_DIR/harmonia.key" "{{secretsDir}}/harmonia.pub"
		export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}
		just _log "Injecting Harmonia private key into sops..." "SOPS"
		HARMONIA_KEY=$(cat "$TMP_DIR/harmonia.key")
		sops set {{sopsSecretsFile}} '["harmonia-secret-key"]' "\"$HARMONIA_KEY\""
		wipe -rf "$TMP_DIR"
	else
		just _info "Harmonia public key already exists." "SOPS"
	fi

	# Everything the declared services need and nobody has to know: OIDC client
	# secrets, backup credentials, service-to-service tokens... Re-run this
	# recipe after enabling a service to converge the new entries.
	just _gen-secrets
	just _fix_fs_permissions
	just _done

# Auto-switching here means the chained `copy-id` / `copy-hw` / `push-key`
# already inherit the nix user — their own guards short-circuit cleanly.
#
# `ip`: network address to reach the node ('auto' = resolved by `_target`).
# Configuring a host that sits outside its own zone also installs the ssh
# redirection, so the `apply` that follows reaches it instead of its home
# address; `just roaming-clear {{host}}` drops it once the host is back home.
#
# New host: ssh cp id, extr. hw, push infra key, tailnet enroll, clean, info
[group('configure')]
configure host ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	t=$(just _resolve "{{host}}" "{{ip}}")
	just copy-id "{{host}}" "$t"
	just copy-hw "{{host}}" "$t"
	just push-key "{{host}}" "$t"

	# LUKS provisioning is a no-op on unencrypted hosts and idempotent on
	# encrypted ones (secrets/manifest/initrd key created only when missing).
	just luks "{{host}}" '' "$t"

	# No-op without Tailscale or once enrolled. An unreachable HCS must not
	# abort an install: warn, the recipe re-runs alone.
	just tailnet-enroll "{{host}}" "$t" || just _warn "Tailnet enrollment failed, re-run: just tailnet-enroll {{host}}"

	# Only a genuinely away address deserves a redirection. `full-install`
	# always hands over an IP — whatever `_wait-any` found — so testing against
	# the name alone installed one on EVERY install, including for a host
	# sitting at home at its own declared address. The stanza disables host key
	# checking for good, so an unnecessary one is not harmless.
	home=$({{nix}} eval --raw --impure --expr '
	  let
	    hosts = import {{workDir}}/var/generated/hosts.nix;
	    matches = builtins.filter (h: h.hostname == "{{host}}") hosts;
	  in if matches == [ ] then "" else (builtins.head matches).ip or ""
	' 2>/dev/null || echo "")
	if [ "$t" != "{{host}}" ] && [ "$t" != "$home" ] ;then
		just roaming "{{host}}" "$t"
	fi
	just _log "If no error occurs, do not forget to commit and apply:"
	just _log "git add . && git commit -m 'Configuring new host {{host}}'"
	just _log "just apply-verbose {{host}}"
	just host-info "{{host}}" "$t"

# The key travels from the HCS to the host through a pipe only: never in argv,
# a variable, the sudo I/O logs or on disk. The HCS mints it for the declared
# tags of the host, whatever the caller asks. Idempotent: a node holding its
# declared name and tags is left alone, a wrong tag or name is fixed in place,
# the offline registration a reinstall left behind is replaced.
#
# Enroll a host in the tailnet (single-use tagged key, idempotent)
[group('configure')]
tailnet-enroll host ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just tailnet-enroll "{{host}}" "{{ip}}"
	cfg={{workDir}}/etc/config.yaml
	if [ "$(yq -r '.network.coordination.enable // false' "$cfg")" != "true" ] ;then
		just _info "No coordination server, nothing to enroll." "TAILNET"
		exit 0
	fi
	hcs=$(yq -r '.network.coordination.hostname' "$cfg")
	enroll=/run/current-system/sw/bin/dnf-tailnet-enroll
	join=/run/current-system/sw/bin/dnf-tailnet-join
	t=$(just _resolve "{{host}}" "{{ip}}")
	on() { ssh -o BatchMode=yes -o ConnectTimeout=15 "nix@$1" "${@:2}" ; }

	# Status needs no root. Exit 3 means no client; anything else, ssh's own
	# 255 included, leaves the state unknown.
	rc=0
	self=$(on "$t" 'command -v tailscale >/dev/null || exit 3; tailscale status --json --peers=false') || rc=$?
	case $rc in
		0) ;;
		3) just _info "{{host}} runs no Tailscale client, nothing to enroll." "TAILNET" ; exit 0 ;;
		*) just _fail "{{host}} at $t: Tailscale status unreadable, ssh or tailscaled down." ;;
	esac
	state=$(jq -r '.BackendState' <<<"$self")
	nodeKey=$(jq -r '.Self.PublicKey // ""' <<<"$self")
	status=$(on "$hcs" sudo "$enroll" status "{{host}}" "$nodeKey")
	want=$(jq -c '.declared' <<<"$status")
	[ "$want" != null ] || just _fail "{{host}}: no declared tailnet identity on $hcs (no tag, or $hcs not deployed since)."

	# Enrolled: headscale knows the node key and the host still holds its login.
	if [ "$(jq -r '.node != null' <<<"$status")" = true ] && [[ $state =~ ^(Running|Stopped|Starting)$ ]] ;then
		just _info "{{host}} already enrolled, backend $state." "TAILNET"
	else
		just _log "{{host}} not enrolled, backend $state: sending a single-use key..." "TAILNET"
		self=$(on "$hcs" sudo "$enroll" key "{{host}}" | on "$t" sudo "$join") \
			|| just _fail "{{host}}: enrollment failed, see above."
		state=$(jq -r '.state' <<<"$self")
		nodeKey=$(jq -r '.nodeKey // ""' <<<"$self")
		[[ $state =~ ^(Running|Stopped)$ ]] \
			|| just _fail "{{host}}: registration failed, backend $state. See journalctl -u tailscaled-autoconnect on {{host}}."
	fi
	node=$(on "$hcs" sudo "$enroll" adopt "{{host}}" "$nodeKey")

	# `adopt` converges; check its outcome rather than trust it.
	summary=$(jq -r '"\(.name) \(.tags | join(",")) \(.ipv4)"' <<<"$node")
	[ "$(jq -r '.name' <<<"$node")" = "{{host}}" ] && [ "$(jq -c '.tags' <<<"$node")" = "$(jq -c '.tags' <<<"$want")" ] \
		|| just _fail "{{host}}: node $summary does not match its declared identity."
	ip=$(jq -r '.ipv4 // ""' <<<"$node")
	declaredIp=$(jq -r '.ipv4 // ""' <<<"$want")
	if [ -n "$declaredIp" ] && [ "$ip" != "$declaredIp" ] ;then
		just _warn "{{host}}: tailnet IP $ip, declared $declaredIp: update etc/config.yaml."
	fi
	just _info "{{host}}: $summary" "TAILNET"

# Provision the Matrix alert bot + rooms (idempotent) from network.matrix.
# Reads config.yaml (network.matrix.{admin,bot}), creates/refreshes the bot,
# webhook secret and the warnings/incidents rooms, and writes the resulting
# room IDs back into config.yaml. Re-run any time; it only fixes what's missing.
#
# Provision the Matrix alert bot and its rooms (idempotent)
[group('configure')]
configure-alert-bot:
	#!/usr/bin/env bash
	set -euo pipefail
	WORKDIR="{{workDir}}" bash {{scriptsDir}}/configure-alert-bot.sh
	just _fix_fs_permissions
