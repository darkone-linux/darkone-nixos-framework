# Darkone framework — consumer project Justfile
# darkone@darkone.yt
#
# Imported by the consumer root Justfile (./Justfile). Imports common.just
# which provides shared parameters, helper functions, check/dev recipes,
# generators, and git helpers.

import 'common.just'

# Project-specific param: the repo-side gitignore path for secrets.
secretsGitIgnore := secretsDir + '/.gitignore'
sopsAdminKeyDir := home_directory() + '/.config/sops/age'
sopsAdminKeyFile := sopsAdminKeyDir + '/keys.txt'
sopsYamlFile := secretsDir + '/.sops.yaml'
sopsInfraTargetFile := sopsInfraTargetDir + '/infra.key'
generatedConfigFile := workDir + '/var/generated/config.yaml'
dnfInstallDir := '/mnt/dnf-install'

alias a := apply
alias al := apply-local
alias av := apply-verbose
alias e := enter

#==============================================================================
# Development
#==============================================================================

# Clean + amend (both repos) + apply-local (or on host) + Test
[group('dev')]
cat host='':
	#!/usr/bin/env bash
	set -euo pipefail
	just clean
	just amend
	if [ "{{host}}" == "" ] ;then
		just apply-local test
	else
		just apply-verbose "{{host}}"
	fi

# Update all flake inputs (dnf/ + root), commit and align locks
[group('dev')]
update-flake:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Updating dnf/ flake inputs..." "FLAKE"
	(cd {{workDir}}/dnf && {{nix}} flake update)
	last_msg=$(git -C {{workDir}}/dnf log -1 --format=%s 2>/dev/null || echo "")
	if [[ "$last_msg" == "update(flake):"* ]]; then
		just _log "Amending existing update(flake) commit..." "FLAKE"
		just amend
	else
		just commit "update(flake): Regular NixOS Update"
	fi
	just _log "Updating root flake inputs..." "FLAKE"
	cd {{workDir}} && {{nix}} flake update
	just amend

# Refresh flake.lock's dnf input to the framework's HEAD (co-dev)
[group('dev')]
update-dnf:
	#!/usr/bin/env bash
	set -euo pipefail

	# Release mode (no dnf/ checkout): framework pinned to a remote rev, nothing
	# local to track — leave the lock untouched.
	if [ ! -d "{{workDir}}/dnf/.git" ]; then
		just _info "No dnf/ checkout — leaving lock untouched." "FLAKE"
		exit 0
	fi
	cd {{workDir}}
	head=$(git -C dnf rev-parse HEAD)
	locked=$({{nix}} eval --raw --impure --expr '(builtins.fromJSON (builtins.readFile "{{workDir}}/flake.lock")).nodes.dnf.locked.rev or ""' 2>/dev/null || echo "")

	# git+file: only deploys committed state; warn so dirty edits aren't silently skipped.
	if ! git -C dnf diff --quiet || ! git -C dnf diff --cached --quiet; then
		just _warn "dnf/ has uncommitted changes — commit them before apply to deploy them."
	fi
	if [ "$locked" = "$head" ]; then
		just _info "dnf lock already up to date." "FLAKE"
	else
		just _log "Refreshing dnf lock..." "FLAKE"
		{{nix}} flake update dnf
	fi

#==============================================================================
# Installation
#==============================================================================

# Copy pub key to the node (nix user must exist)
[group('install')]
copy-id host:
	#!/usr/bin/env bash
	set -euo pipefail
	if sudo -i -u nix ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o BatchMode=yes nix@{{host}} "true"; then
		just _info "SSH key already exists for {{host}}, continue..." "SSH"
	else
		just _log "Copying id to {{host}}..." "SSH"
		sudo -i -u nix ssh-keygen -R {{host}}
		sudo -i -u nix ssh-copy-id -o StrictHostKeyChecking=no -f nix@{{host}}
	fi
	just _log "Cleaning authorized_keys..." "SSH"
	sudo -i -u nix ssh nix@{{host}} "sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys"
	sudo -i -u nix ssh -o PasswordAuthentication=no -o PubkeyAuthentication=yes nix@{{host}} 'echo "OK, it works!"'

# Framework installation on local machine (builder / admin)
[group('install')]
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
			just _fail "Nix user public key not found!" "SSH"
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
		just _log "[SOPS] .sops.yaml file generation..."
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
	# public key committed (read by ncps to trust harmonia-signed paths).
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
	just _fix_fs_permissions
	just _done

# Extract hardware config from host
[group('install')]
copy-hw host:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Extracting hardware information..."
	mkdir -p usr/machines/{{host}}
	sudo -i -u nix ssh nix@{{host}} "sudo nixos-generate-config --no-filesystems --show-hardware-config" > {{workDir}}/usr/machines/{{host}}/hardware-configuration.nix
	nixfmt -s usr/machines/{{host}}/hardware-configuration.nix

# Push the infrastructure key to the host
[group('install')]
push-key host:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just push-key "{{host}}"
	just _check_infra_admin
	just _log "Pushing infra key file..." "SOPS"
	ssh nix@{{host}} 'sudo mkdir -p {{sopsInfraTargetDir}}'
	ssh nix@{{host}} 'sudo chown -R nix {{sopsInfraTargetDir}}'
	scp {{sopsInfraKeyFile}} nix@{{host}}:{{sopsInfraTargetFile}}
	ssh nix@{{host}} 'sudo chown -R root {{sopsInfraTargetDir}}'
	ssh nix@{{host}} 'sudo chmod 600 {{sopsInfraTargetFile}}'

# Confirmation prompt is inlined (instead of using the `[confirm]` attribute)
# so it fires only once, after the sudo re-exec.
#
# New host: format with nixos-everywhere + disko
[group('install')]
install host user='nix' ip='auto' do='install':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" != "nix" ] || just _fail "Do not full-install with nix user but with the owner of your code.";
	read -p "Are you sure to format disks and install a new system? (y/N) " ans
	[ "$ans" = "y" ] || { just _log "Aborted." "INSTALL"; exit 1; }
	just _fix_fs_permissions
	just _check_infra_admin
	just clean
	just _log "Preparation..."
	if [ ! -f "./usr/machines/{{host}}/default.nix" ]; then
		just _fail "Host '{{host}}' not found. Check it exists and has a disko config in etc/config.yaml."
	fi
	echo "{ }" > ./usr/machines/{{host}}/hardware-configuration.nix
	if [ "{{ip}}" == "auto" ]; then
		TARGET_HOST="{{host}}"
	else
		TARGET_HOST="{{ip}}"
	fi
	just _fix_fs_permissions
	just _log "We need to add, commit and build..."
	git add . && (git diff --cached --quiet || git commit -m "New host {{host}} dnf installation") && git reset
	just _log "Launching installation ({{do}})..."
	if [ "{{do}}" == "test" ]; then
		{{nix}} run github:nix-community/nixos-anywhere -- --flake .#{{host}} --vm-test
	elif [ "{{do}}" == "install" ] ;then
		NIX_HOME=$(getent passwd nix | cut -d: -f6)
		mkdir -p {{workDir}}/usr/machines/{{host}}
		sudo chown -R nix {{workDir}}/usr/machines/{{host}}
		sudo chown -R nix /etc/nixos/.git
		sudo -i -u nix {{nix}} run github:nix-community/nixos-anywhere -- \
			--copy-host-keys \
			--flake "{{workDir}}#{{host}}" \
			-i "${NIX_HOME}/.ssh/id_ed25519" \
			--generate-hardware-config nixos-generate-config {{workDir}}/usr/machines/{{host}}/hardware-configuration.nix \
			--target-host {{user}}@$TARGET_HOST
		just _fix_fs_permissions
	else
		just _fail "Unknown action '{{do}}' — valid values: install, test"
	fi
	just _log "Now you can test nix@{{host}} and run 'just configure {{host}}'"

# Inlined confirmation, same rationale as `install`.
#
# Format a USB key (or local device) with disko and install NixOS on it
[group('install')]
install-key host:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just install-key "{{host}}"
	read -p "Are you sure to format the device and install a new system? (y/N) " ans
	[ "$ans" = "y" ] || { just _log "Aborted." "INSTALL-KEY"; exit 1; }
	just _check_infra_admin
	just _log "Preparation..."
	if [ ! -f "./usr/machines/{{host}}/default.nix" ]; then
		just _fail "Host '{{host}}' not found. Check it exists and has a disko config in etc/config.yaml."
	fi
	sudo mkdir -p {{dnfInstallDir}}
	sudo chmod 750 {{dnfInstallDir}}
	just _log "Hardware configuration for usb key..."
	echo "_:{imports=[./../../../dnf/hosts/templates/hardware-usb-key.nix];}" > ./usr/machines/{{host}}/hardware-configuration.nix
	just clean
	just _fix_fs_permissions
	just _log "We need to add, commit and build..."
	git add . && (git diff --cached --quiet || git commit -m "New host {{host}} dnf installation") && git reset
	just _log "Launching format with disko..."
	sudo {{nix}} run github:nix-community/disko -- \
	  --mode disko \
	  --root-mountpoint {{dnfInstallDir}} ./usr/machines/{{host}}/disko.nix
	just _log "NixOS DNF installation..."
	sudo nixos-install --flake '.#{{host}}' --root {{dnfInstallDir}} --no-root-password
	just _log "Unmounting new system..."
	sudo umount -R {{dnfInstallDir}}
	sudo rmdir {{dnfInstallDir}}
	just _log "End of key installation"

# Get a mac address
_host-info host:
	#!/usr/bin/env bash
	set -euo pipefail
	MAC_ADDR=`sudo -i -u nix ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=no -o PubkeyAuthentication=yes nix@{{host}} "ip -o link show up | grep -v 'lo:' | head -n 1 | sed 's/^.* \([0-9a-f:]*\) brd .*$/\1/'"`
	just _log "You can register the mac address in etc/config.yaml: {{GREEN}}$MAC_ADDR{{NORMAL}}"

# Auto-switching here means the chained `copy-id` / `copy-hw` / `push-key`
# already inherit the nix user — their own guards short-circuit cleanly.
#
# New host: ssh cp id, extr. hw, push infra key, clean, info
[group('install')]
configure host:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	just copy-id "{{host}}"
	just copy-hw "{{host}}"
	just push-key "{{host}}"
	just _log "If no error occurs, do not forget to commit and apply:"
	just _log "git add . && git commit -m 'Installing new host {{host}}'"
	just _log "just apply-verbose {{host}}"
	just _host-info "{{host}}"

# New host: full installation (install, configure, apply)
[group('install')]
full-install host user='nixos' ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	just install {{host}} {{user}} {{ip}}
	just _log "Waiting for reboot..."
	until ping -c1 -W1 {{host}} >/dev/null 2>&1; do sleep 1; done; echo "Oh, {{host}} is up, waiting 2s and continue... :)"
	sleep 2
	just configure {{host}}
	just _log "Let's do that automatically..."
	#just _fix_fs_permissions
	just _log "Adding and committing (amend)..." "GIT"
	git add . && (git diff --cached --quiet || git commit --amend --no-edit --allow-empty) && git reset
	just apply-verbose {{host}}
	just _log "Cleaning new system..."
	just gc {{host}}
	just _log "Last reboot..."
	sudo -i -u nix colmena exec --config "{{workDir}}/flake.nix" --on "{{host}}" "nohup bash -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &"
	just _done
	just _log "Don't forget to comment or remove disko config in etc/config.yaml."

# Update the default DNF password
[group('install')]
passwd-default:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just passwd-default
	cd {{secretsDir}}
	echo -n "New default DNF password: "
	read -s PASSWORD
	echo
	echo -n "Please confirm: "
	read -s PASSWORD_CONFIRM
	echo
	if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
		just _fail "Error: not corresponding."
	fi
	export PASSWORD
	BCRYPT_HASH=$(mkpasswd --method=bcrypt --rounds=12 "$PASSWORD")
	export BCRYPT_HASH
	just _sops_before_edit
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}
	just _log "Updating default password..." "SOPS"
	if [ -f {{sopsSecretsFile}} ] ;then
		sops -d -i {{sopsSecretsFile}}
	else
		echo "{}" >> {{sopsSecretsFile}}
	fi
	yq --inplace '."default-password" = strenv(PASSWORD)' {{sopsSecretsFile}}
	yq --inplace '."default-password-hash" = strenv(BCRYPT_HASH)' {{sopsSecretsFile}}
	sops -e -i {{sopsSecretsFile}}

	# var/generated/ is owned by the workspace user (generator output, committed
	# to git). yq --inplace does an atomic rename and needs write access on the
	# parent dir, not just on the file. Hand both to nix for the duration of the
	# write; _fix_fs_permissions (below) restores ownership via --reference=. at the end.
	sudo mkdir -p "$(dirname {{generatedConfigFile}})"
	sudo chown nix "$(dirname {{generatedConfigFile}})"
	if [ -f {{generatedConfigFile}} ] ;then
		sudo chown nix {{generatedConfigFile}}
	fi
	if [ ! -f {{generatedConfigFile}} ] ;then
		echo "{}" >> {{generatedConfigFile}}
	fi
	yq --inplace '.network.default."password-hash" = strenv(BCRYPT_HASH)' {{generatedConfigFile}}
	just _fix_fs_permissions
	just _log "Password updated, don't forget to deploy" "SOPS"

# Update a user password
[group('install')]
passwd user:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just passwd "{{user}}"
	if [ ! -f {{sopsSecretsFile}} ] ;then
		echo "No secrets sops file found, run 'just install-admin-host' before."
		exit 1
	fi
	cd {{secretsDir}}
	echo -n "New password for {{user}}: "
	read -s PASSWORD
	echo
	echo -n "Please confirm: "
	read -s PASSWORD_CONFIRM
	echo
	if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
		just _fail "Error: not corresponding."
	fi

	# sops -i and yq --inplace both do an atomic rename inside usr/secrets/, which
	# is darkone-owned in the default state. _sops_before_edit chowns it to
	# nix for the duration of the edit; _fix_fs_permissions restores at the
	# end. Same export as passwd-default so sops can decrypt without relying
	# on the ambient ~/.config/sops/age key.
	just _sops_before_edit
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}
	just _log "Updating {{user}} password..." "SOPS"
	HASH=$(mkpasswd -m sha-512 "$PASSWORD")
	export HASH
	sops -d -i {{sopsSecretsFile}}
	yq --inplace '.user."{{user}}"."password-hash" = strenv(HASH)' {{sopsSecretsFile}}
	sops -e -i {{sopsSecretsFile}}
	just _fix_fs_permissions
	just _log "OK, password updated for {{user}}" "SOPS"
	just _log "Now deploy with 'just apply @user-{{user}}'" "SOPS"

# Edit sops secrets
[group('install')]
sops:
	#!/usr/bin/env bash
	set -euo pipefail
	just _sops_before_edit
	sudo -i -u nix EDITOR=vim sops {{sopsSecretsFile}}
	just _fix_fs_permissions

# Sync Kanidm replication certificates (multi-zone read-only replicas).
#
# Replication is automatic when idm runs on the HCS and >=1 zone gateway. Bootstrap
# is a two-step deploy:
#   1. `just apply` once  -> each replication node generates its identity.
#   2. `just idm-sync-certs` -> collect the public certs into usr/secrets.
#   3. commit + `just apply` again -> partner blocks appear, replication starts.
# Re-run any time a replica is added. Certs are public; safe to commit.
#
# Runs as the current (admin) user so the collected files stay user-owned and
# committable. Only the per-node SSH needs the `nix` deploy identity (its keys,
# config and known_hosts live in ~nix/.ssh), so just that call uses `sudo -u nix`.
[group('install')]
idm-sync-certs:
	#!/usr/bin/env bash
	set -euo pipefail
	dest="{{secretsDir}}/replication"
	mkdir -p "$dest"

	# TODO: itérer uniquement sur HCS et gateways... un peu long d'aller chercher sur 150 noeuds.
	nodes=$(just _hive-nodes)
	[ -n "$nodes" ] || just _fail "No hive nodes found (colmena eval failed?)."
	found=0
	for node in $nodes ;do

		# show-replication-certificate only succeeds on a node that has a
		# [replication] block; other hosts fail and are skipped. The cert body
		# is the bare DER (MII...) that goes verbatim into supplier/consumer.
		# Kanidm emits it in base64url (URL-safe `-`/`_`), so the class must
		# accept both alphabets — otherwise the cert is truncated at the first
		# `-`/`_`. `-H` gives ssh the nix user's HOME so it uses ~nix/.ssh.
		cert=$(sudo -u nix -H ssh -o BatchMode=yes nix@"$node" \
			'sudo kanidmd show-replication-certificate -c /etc/kanidm/server.toml 2>/dev/null | grep -oE "MII[A-Za-z0-9+/=_-]+" | head -n1' \
			2>/dev/null || true)
		if [ -n "$cert" ] ;then
			echo "$cert" > "$dest/${node}.pem"
			just _info "Synced replication cert for ${node}." "IDM"
			found=$((found+1))
		else
			just _info "No replication cert on ${node} (skipped)." "IDM"
		fi
	done
	[ "$found" -gt 0 ] || just _warn "No replication certificates collected — did you 'just apply' first?"
	just _log "Done. Commit usr/secrets/replication/ then 'just apply' again to activate replication." "IDM"

# Diagnose Kanidm replication health and prescribe the exact remediation steps.
#
# Read-only "doctor": never wipes, restarts or applies anything. Pass the supplier
# (the HCS / coordination host) and the comma-separated consumer gateways, e.g.
#   just idm-fix-replica hcs agate,gw
# The usual blocker is dangling references in the supplier database that make the
# replication refresh fail (post_repl_refresh referential-integrity check). This
# checks supplier integrity, certificate sync and each consumer's last refresh,
# then prints a copy-pasteable checklist. Same SSH/identity conventions as
# idm-sync-certs (only the per-node SSH uses the nix deploy user).
[group('install')]
idm-fix-replica supplier consumers:
	#!/usr/bin/env bash
	set -euo pipefail
	dest="{{secretsDir}}/replication"
	supplier="{{supplier}}"
	IFS=',' read -ra consumers <<< "{{consumers}}"
	ok=1
	refint_fail=0

	# Live replication certificate of a node (empty if it has no [replication]).
	repl_cert() {
		sudo -u nix -H ssh -o BatchMode=yes nix@"$1" \
			'sudo kanidmd show-replication-certificate -c /etc/kanidm/server.toml 2>/dev/null | grep -oE "MII[A-Za-z0-9+/=_-]+" | head -n1' \
			2>/dev/null || true
	}

	# Synced .pem for a node (single line, whitespace stripped), empty if absent.
	synced_cert() { [ -f "$dest/$1.pem" ] && tr -d '\n\r ' < "$dest/$1.pem" || true; }

	# Remote command as the nix deploy user; never abort the recipe on failure.
	on() { sudo -u nix -H ssh -o BatchMode=yes nix@"$1" "$2" 2>/dev/null || true; }

	just _log "Diagnostic de la réplication Kanidm (supplier=$supplier)" "IDM"

	# Local: every cert must exist AND be git-tracked, else the flake eval ignores it.
	for n in "$supplier" "${consumers[@]}" ;do
		if [ ! -f "$dest/$n.pem" ] ;then
			just _warn "Cert $n.pem absent (sync manquante)." ; ok=0
		elif ! git -C {{workDir}} ls-files --error-unmatch "$dest/$n.pem" >/dev/null 2>&1 ;then
			just _warn "Cert $n.pem NON suivi par git → invisible au flake ('git add' requis)." ; ok=0
		fi
	done

	# Supplier: service up, cert in sync, database referential integrity.
	just _log "Supplier $supplier" "IDM"
	act=$(on "$supplier" 'systemctl is-active kanidm')
	just _info "kanidm: ${act:-injoignable}" "IDM"
	[ "$act" = "active" ] || ok=0
	live=$(repl_cert "$supplier") ; sync=$(synced_cert "$supplier")
	if [ -z "$live" ] ;then
		just _warn "Pas de cert de réplication live sur $supplier." ; ok=0
	elif [ "$live" != "$sync" ] ;then
		just _warn "Cert HCS live ≠ cert synchronisé → consumers en UnknownCA (re-sync requise)." ; ok=0
	else
		just _info "Cert de réplication en phase." "IDM"
	fi
	verify=$(on "$supplier" 'sudo kanidmd database verify -c /etc/kanidm/server.toml 2>&1')
	if printf '%s' "$verify" | grep -qE 'RefintNotUpheld|Err\(' ;then
		just _err "Intégrité base HCS: ÉCHEC (références pendantes) :"
		printf '%s\n' "$verify" | grep -E 'RefintNotUpheld|Err\(' | sed 's/^/      /'
		refint_fail=1 ; ok=0
	else
		just _info "Intégrité base HCS: OK." "IDM"
	fi

	# Consumers: service up, role, supplier_cert freshness, last refresh outcome.
	for c in "${consumers[@]}" ;do
		just _log "Consumer $c" "IDM"
		act=$(on "$c" 'systemctl is-active kanidm')
		role=$(on "$c" "grep -oE '^role[[:space:]]*=.*' /etc/kanidm/server.toml")
		just _info "kanidm: ${act:-injoignable} | ${role:-role inconnu}" "IDM"
		[ "$act" = "active" ] || ok=0
		conf=$(on "$c" "grep -oE 'MII[A-Za-z0-9+/=_-]+' /etc/kanidm/server.toml | head -n1")
		if [ -n "$sync" ] && [ -n "$conf" ] && [ "$conf" != "$sync" ] ;then
			just _warn "supplier_cert de $c périmé (≠ cert HCS courant) → UnknownCA." ; ok=0
		fi
		jr=$(on "$c" 'journalctl -u kanidm --since -10min --no-pager')
		if printf '%s' "$jr" | grep -q 'ReferentialIntegrity' ;then
			just _warn "Dernier refresh: ÉCHEC intégrité référentielle (corruption supplier)." ; ok=0
		elif printf '%s' "$jr" | grep -q 'UnknownCA' ;then
			just _warn "Dernier refresh: ÉCHEC UnknownCA (cert périmé)." ; ok=0
		elif printf '%s' "$jr" | grep -qE 'consumer_apply_refresh|Reindexed' ;then
			just _info "Dernier refresh: OK." "IDM"
		else
			just _info "Dernier refresh: aucun récent." "IDM"
		fi
	done

	# Verdict + prescription (printed only; nothing is executed).
	if [ "$ok" = 1 ] ;then
		just _log "Réplication saine — rien à faire. ✅" "IDM"
		exit 0
	fi
	just _warn "Réplication NON saine — prescription ci-dessous :"
	echo
	if [ "$refint_fail" = 1 ] ;then
		echo "  [HCS] Base corrompue (RefintNotUpheld) : le refresh échouera tant"
		echo "  qu'elle n'est pas réparée. kanidm n'a pas de 'repair refint'."
		echo "  Remède : RESTAURER la base HCS depuis une sauvegarde SAINE (antérieure"
		echo "  à la corruption — une sauvegarde récente peut être déjà corrompue),"
		echo "  puis resynchroniser le cert (la restauration peut le changer) :"
		echo
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo systemctl stop kanidm'"
		echo "    #  ... restaure /var/lib/kanidm/kanidm.db depuis ta sauvegarde ..."
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo systemctl start kanidm'"
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo kanidmd database verify -c /etc/kanidm/server.toml'  # doit être OK"
		echo "    just idm-sync-certs"
		echo "    git add usr/secrets/replication && git commit -m 'fix(idm): resync replication certs'"
		echo "    just apply $supplier,{{consumers}}"
		echo "    # forcer le 1er refresh sur un consumer si besoin :"
		echo "    sudo -u nix -H ssh nix@<consumer> 'sudo kanidmd refresh-replication-consumer -c /etc/kanidm/server.toml'"
	else
		echo "  Certs désynchronisés. Resynchronise et redéploie :"
		echo
		echo "    just idm-sync-certs"
		echo "    git add usr/secrets/replication && git commit -m 'fix(idm): resync replication certs'"
		echo "    just apply $supplier,{{consumers}}"
	fi
	echo

#==============================================================================
# Rotation
#==============================================================================
#
# Infra age key rotation, in three explicit, integrity-checked steps:
#   1. just rotate init       generate a new key, keep the old one as a second
#                             recipient, re-encrypt secrets to both.
#   2. just rotate push-keys  push the combined (new+old) key to every hive
#                             host, so each one decrypts whatever its store
#                             holds, in any apply/push order.
#   3. just rotate finalize   once every host carries the new key (verified
#                             first), drop the old one, re-encrypt to the new
#                             key only and push the new-only key everywhere.
#
# The presence of /etc/sops/age/infra.key.old marks a rotation in progress.

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

# List all colmena hive node names (the deploy source of truth), one per line.
_hive-nodes:
	#!/usr/bin/env bash
	set -euo pipefail
	colmena eval --config {{workDir}}/flake.nix -E '{ nodes, ... }: builtins.attrNames nodes' 2>/dev/null \
		| grep -oE '"[^"]+"' | tr -d '"'

# Rotate the infra age key (step: init | push-keys | finalize)
[group('install')]
rotate step:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just rotate "{{step}}"
	case "{{step}}" in
		init)      just _rotate-infra-init ;;
		push-keys) just _rotate-infra-push-keys ;;
		finalize)  just _rotate-infra-finalize ;;
		*) just _fail "Unknown rotate step '{{step}}' — valid: init, push-keys, finalize" ;;
	esac

# Rotation step 1: introduce a new infra key alongside the old one.
_rotate-infra-init:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	if [ -f {{sopsInfraOldKeyFile}} ] || [ -f {{sopsInfraCurKeyFile}} ] ;then
		just _err "A rotation is already in progress."
		just _fail "Run 'just rotate push-keys' then 'just rotate finalize' (or remove {{sopsInfraCurKeyFile}} / {{sopsInfraOldKeyFile}} to abort)."
	fi
	if [ ! -s {{sopsAdminKeyFile}} ] ;then
		just _fail "Admin age key not found ({{sopsAdminKeyFile}}). Run 'just configure-admin-host' first."
	fi
	if [ ! -f {{sopsSecretsFile}} ] ;then
		just _fail "Secrets file not found ({{sopsSecretsFile}})."
	fi
	just _log "Generating a new infra key (keeping the old one as recipient)..." "ROTATE"

	# Make sure the key store is writable by the nix deploy user.
	sudo mkdir -p {{sopsInfraTargetDir}}
	sudo chown nix {{sopsInfraTargetDir}}

	# Preserve the current single key as .old, generate the new single key as
	# .cur, then make the operational infra.key the concatenation new+old: any
	# host that receives it decrypts secrets sealed for either identity.
	cp {{sopsInfraKeyFile}} {{sopsInfraOldKeyFile}}
	age-keygen -o {{sopsInfraCurKeyFile}}
	cat {{sopsInfraCurKeyFile}} {{sopsInfraOldKeyFile}} > {{sopsInfraKeyFile}}
	chmod 600 {{sopsInfraCurKeyFile}} {{sopsInfraOldKeyFile}} {{sopsInfraKeyFile}}

	# Re-encrypt secrets to admin + new + old, decrypting with the stable admin
	# key. sops resolves .sops.yaml from the CWD, so run it from the secrets dir
	# (same pattern as passwd-default), in a subshell to keep the recipe CWD.
	just _regen-sops-yaml
	just _log "Re-encrypting secrets for new + old recipients..." "ROTATE"
	( cd {{secretsDir}} && SOPS_AGE_KEY_FILE={{sopsAdminKeyFile}} sops updatekeys -y {{sopsSecretsFile}} )
	just _fix_fs_permissions
	just _log "Init done. Commit, deploy ('just apply ...'), then 'just rotate push-keys'." "ROTATE"

# Rotation step 2: push the combined key to every hive host.
_rotate-infra-push-keys:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	if [ ! -f {{sopsInfraOldKeyFile}} ] ;then
		just _fail "No rotation in progress. Run 'just rotate init' first."
	fi
	self=$(hostname)

	# Fail safe: an empty list means colmena eval failed — never report success
	# (or, in finalize, prune the old key) against zero hosts.
	nodes=$(just _hive-nodes)
	[ -n "$nodes" ] || just _fail "No hive nodes found (colmena eval failed?). Aborting."
	just _log "Pushing combined infra key to all hive hosts..." "ROTATE"
	failed=()
	for node in $nodes ;do

		# The admin host already holds the combined key locally; never scp to
		# self (push-key would chown the key to root and lock the tooling out).
		if [ "$node" = "$self" ] ;then
			just _info "Skipping admin host $node (already up to date)." "ROTATE"
			continue
		fi
		if just push-key "$node" ;then
			just _info "Pushed to $node." "ROTATE"
		else
			just _warn "Push FAILED for $node."
			failed+=("$node")
		fi
	done
	if [ ${#failed[@]} -ne 0 ] ;then
		just _fail "Key not delivered to: ${failed[*]} — fix connectivity and re-run 'just rotate push-keys'."
	fi
	just _log "All hosts have the combined key. After 'just apply' everywhere, run 'just rotate finalize'." "ROTATE"

# Rotation step 3: verify every host carries the new key, then drop the old one.
_rotate-infra-finalize:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	if [ ! -f {{sopsInfraOldKeyFile}} ] || [ ! -f {{sopsInfraCurKeyFile}} ] ;then
		just _fail "No rotation in progress (nothing to finalize). Run 'just rotate init' first."
	fi
	if [ ! -s {{sopsAdminKeyFile}} ] ;then
		just _fail "Admin age key not found ({{sopsAdminKeyFile}})."
	fi
	self=$(hostname)
	NEW_PUB=$(age-keygen -y {{sopsInfraCurKeyFile}})

	# Fail safe: empty list => colmena eval failed; never prune against zero hosts.
	nodes=$(just _hive-nodes)
	[ -n "$nodes" ] || just _fail "No hive nodes found (colmena eval failed?). Aborting."

	# Integrity gate: refuse to drop the old key until EVERY hive host carries
	# the new one (else a host would be left unable to decrypt). Unreachable
	# hosts count as missing.
	just _log "Verifying every host carries the new key..." "ROTATE"
	missing=()
	for node in $nodes ;do
		[ "$node" = "$self" ] && continue
		tmp=$(mktemp)
		if ssh -o BatchMode=yes nix@"$node" 'sudo cat {{sopsInfraKeyFile}}' > "$tmp" 2>/dev/null \
			&& age-keygen -y "$tmp" 2>/dev/null | grep -qxF "$NEW_PUB" ;then
			just _info "$node OK." "ROTATE"
		else
			just _warn "$node is missing the new key (or unreachable)."
			missing+=("$node")
		fi
		rm -f "$tmp"
	done
	if [ ${#missing[@]} -ne 0 ] ;then
		just _fail "Cannot finalize — these hosts lack the new key: ${missing[*]}. Run 'just rotate push-keys' (and 'just apply') first."
	fi
	just _log "All hosts verified. Dropping the old key..." "ROTATE"

	# Operational key becomes the new single identity; remove the sidecars.
	mv {{sopsInfraCurKeyFile}} {{sopsInfraKeyFile}}
	rm -f {{sopsInfraOldKeyFile}}
	chmod 600 {{sopsInfraKeyFile}}

	# Re-encrypt secrets to admin + new only (the old key becomes useless).
	# Run sops from the secrets dir (CWD-based .sops.yaml discovery).
	just _regen-sops-yaml
	just _log "Re-encrypting secrets for the new key only..." "ROTATE"
	( cd {{secretsDir}} && SOPS_AGE_KEY_FILE={{sopsAdminKeyFile}} sops updatekeys -y {{sopsSecretsFile}} )
	just _fix_fs_permissions

	# Replace the combined key with the new-only key on every host. Hosts we
	# can't reach keep the combined key, so they keep working until re-pushed.
	just _log "Pushing new-only key to all hive hosts..." "ROTATE"
	failed=()
	for node in $nodes ;do
		[ "$node" = "$self" ] && continue
		if just push-key "$node" ;then :; else failed+=("$node"); fi
	done
	if [ ${#failed[@]} -ne 0 ] ;then
		just _warn "New-only key not pushed to: ${failed[*]} — re-run 'just push-key <host>' for them."
	fi
	just _log "Finalize done. Commit and 'just apply' everywhere to flush the old recipient." "ROTATE"

#==============================================================================
# Apply (colmena)
#==============================================================================
#
# TODO: Binary cache keys + remove --build-on-target -> https://nixos.wiki/wiki/Binary_Cache

# Apply configuration using colmena
[group('apply')]
apply on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying nix configuration on {{on}} ({{what}})..."
	if [ "${USER:-}" = "nix" ] ;then
		colmena apply --build-on-target --on "{{on}}" {{what}}
	else
		sudo -i -u nix colmena apply --config "{{workDir}}/flake.nix" --build-on-target --on "{{on}}" {{what}}
	fi

# Apply force with verbose options
[group('apply')]
apply-verbose on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying (verbose) nix configuration on {{on}} ({{what}})..."
	if [ "${USER:-}" = "nix" ] ;then
		colmena apply --build-on-target --verbose --show-trace --on "{{on}}" {{what}}
	else
		sudo -i -u nix colmena apply --config "{{workDir}}/flake.nix" --build-on-target --verbose --show-trace --on "{{on}}" {{what}}
	fi

# Apply the local host configuration
[group('apply')]
apply-local what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying locally ({{what}})..."
	colmena apply-local --sudo {{what}}

#==============================================================================
# Maintenance
#==============================================================================
#
# Same auto-switch pattern as the apply group: each recipe re-execs itself
# under the `nix` user when the caller is somebody else.

# Interactive shell to the host
[group('manage')]
enter on:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Entering {{on}}..." "SSH"
	if [ "${USER:-}" = "nix" ]; then
		ssh nix@{{on}}
	else
		sudo -i -u nix ssh nix@{{on}}
	fi

# Confirmation prompt is inlined (rather than via the `[confirm]` attribute)
# so it fires only once, after the sudo re-exec (stdin is preserved by sudo).
#
# Multi-reboot (using colmena)
[group('manage')]
reboot on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just reboot "{{on}}"
	read -p "Are you sure to reboot {{on}}? (y/N) " ans
	[ "$ans" = "y" ] || { just _log "Aborted." "REBOOT"; exit 1; }
	just _log "Rebooting {{on}}..."
	colmena exec --on "{{on}}" "nohup bash -c 'sleep 1; sudo systemctl reboot -i' >/dev/null 2>&1 &"

# Same single-prompt pattern as `reboot`.
#
# Multi-halt (using colmena)
[group('manage')]
halt on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just halt "{{on}}"
	read -p "Are you sure to halt {{on}}? (y/N) " ans
	[ "$ans" = "y" ] || { just _log "Aborted." "HALT"; exit 1; }
	just _log "Halting {{on}}..."
	colmena exec --on "{{on}}" "nohup bash -c 'sleep 1; sudo systemctl poweroff -i' >/dev/null 2>&1 &"

# Remove zshrc bkp to avoid error when replacing zshrc
[group('manage')]
fix-zsh on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just fix-zsh "{{on}}"
	just _log "Fixing ZSH on {{on}}..."
	colmena exec --on "{{on}}" "rm -f .zshrc.bkp"

# Multi garbage collector (using colmena)
[group('manage')]
gc on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just gc "{{on}}"
	just _log "Garbage collecting on {{on}}..."
	colmena exec --on "{{on}}" "sudo nix-collect-garbage -d && sudo /run/current-system/bin/switch-to-configuration boot"

# Multi-reinstall bootloader (using colmena)
[group('manage')]
fix-boot on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just fix-boot "{{on}}"
	just _log "Fixing boot of {{on}}..."
	colmena exec --on "{{on}}" "sudo NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"

# Run all checks and tests (useful before deploy)
[group('check')]
check-all:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ -d {{workDir}}/dnf ] ;then
		just _log "DNF Unit Tests" "CHECK-ALL"
		cd {{workDir}}/dnf && just unit-tests | grep -v '✅'
		just _log "DNF Flake + Simulation" "CHECK-ALL"
		cd {{workDir}}/dnf && just check-flake
	fi
	just _log "Network flake" "CHECK-ALL"
	cd {{workDir}} && just check-flake
