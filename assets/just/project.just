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

# Deploy build location. Empty (default): build each node closure on the host
# running just, then push it — a derivation compiles once and the deployer's
# harmonia re-serves it to the whole fleet. Non-empty: build on each target
# (use for an arch the deployer cannot build natively, e.g. aarch64 rpi hosts).
buildOnTarget := ''

alias a := apply
alias al := apply-local
alias av := apply-verbose
alias e := enter
alias rd := remote-desktop

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

	# Co-development only: `dnf/` is a git checkout carrying its own lock, and
	# the dual-repo commit helpers of dev.just are imported. In release mode
	# `dnf/` is a read-only store symlink (or absent) — only the root lock moves.
	if [ ! -d "{{workDir}}/dnf/.git" ]; then
		just _log "Updating flake inputs..." "FLAKE"
		cd {{workDir}} && {{nix}} flake update
		exit 0
	fi
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

# Address to reach {{host}} from the machine running just.
#
# Its own name when both sit in the same zone. Otherwise the address the local
# zone reserves for it: every gateway holds a DHCP reservation for each known
# fleet MAC that is not native to its zone (`zone.roaming`, generated), so a
# machine plugged anywhere is predictable before it has even booted.
#
# The local zone is the one whose gateway actually routes this machine, NOT the
# zone it is declared in — an admin laptop is precisely the thing that moves.
# Declaration is only the fallback (deploying over the VPN, gateway itself).
#
# Falls back to the host name when nothing matches: a host with no declared MAC
# is simply not reachable outside its zone.
#
# A reservation is an expectation, not evidence, so the roaming address is
# probed before being returned — see the comment on the probe below.
_target host:
	#!/usr/bin/env bash
	set -euo pipefail
	gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)
	addr=$({{nix}} eval --raw --impure --expr '
	  let
	    hosts = import {{workDir}}/var/generated/hosts.nix;
	    network = import {{workDir}}/var/generated/network.nix;
	    findHost = n:
	      let matches = builtins.filter (h: h.hostname == n) hosts;
	      in if matches == [ ] then null else builtins.head matches;
	    localZones = builtins.filter (z: z.name != "www") (builtins.attrValues network.zones);
	    routedBy = builtins.filter (z: (z.gateway.lan.ip or "") == "'"$gw"'") localZones;
	    me = findHost "'"$(hostname -s)"'";
	    here =
	      if routedBy != [ ] then builtins.head routedBy
	      else if me != null then network.zones.${me.zone} or null
	      else null;
	    target = findHost "{{host}}";
	  in
	  if here == null || target == null || target.zone == here.name
	  then "{{host}}"
	  else here.roaming."{{host}}" or "{{host}}"
	')

	# The roaming reservation says where the host WOULD be if plugged in here.
	# During an install it is right — the machine is on the bench, answering on
	# 22. Once it is back home and reached over the VPN it is a dead address,
	# and every management recipe aimed at it: `just enter` gave up, `just luks`
	# warned and exited 0 while colmena, which addresses nodes by name, still
	# deployed happily. Order below: trust the reservation only if something
	# answers there, otherwise the name if the host responds (2222 included —
	# an encrypted host waiting in its initrd is up, just not booted), and keep
	# the reservation as the last word so a machine not powered on yet still
	# resolves to the address its installer will appear on.
	up() { timeout 2 bash -c ": < /dev/tcp/$1/$2" 2>/dev/null ; }
	if [ "$addr" = "{{host}}" ] ;then
		echo "{{host}}"
	elif up "$addr" 22 ;then
		echo "$addr"
	elif up "{{host}}" 22 || up "{{host}}" 2222 ;then
		echo "{{host}}"
	else
		echo "$addr"
	fi

# Resolve a recipe's `target`/`ip` parameter: 'auto' asks `_target`.
_resolve host target:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ "{{target}}" = "auto" ] ;then
		just _target "{{host}}"
	else
		echo "{{target}}"
	fi

# Wait for a target to come up (or go down) on ssh.
#
# Deliberately not `ping`: a gateway drops ICMP everywhere but on its LAN
# bridge (cf. `modules/service/dnsmasq.nix`), so a box reached from another
# zone never answers a ping while its ssh port is wide open.
_wait-ssh target state='up' timeout='600':
	#!/usr/bin/env bash
	set -euo pipefail
	deadline=$(( $(date +%s) + {{timeout}} ))
	printf 'Waiting for {{target}} to be {{state}}'
	while : ;do
		if timeout 2 bash -c ': < /dev/tcp/{{target}}/22' 2>/dev/null ;then
			current=up
		else
			current=down
		fi
		[ "$current" != "{{state}}" ] || break
		if [ "$(date +%s)" -ge "$deadline" ] ;then
			printf ' timeout\n'
			just _fail "{{target}} is still not {{state}} after {{timeout}}s."
		fi
		printf '.'
		sleep 2
	done
	printf ' OK\n'

# Colmena addresses a node by its name, which DNS resolves to the host's HOME
# address — deploying into the void while the machine is plugged elsewhere.
# A stanza in the nix user's ssh config redirects it, and ssh, scp and colmena
# all honour it without knowing anything about zones. `full-install` clears it
# once the host is configured; call `roaming-clear` after a manual `configure`.
#
# No argument: show the current redirections.
#
# Route ssh to a host that sits outside its own zone.
[group('install')]
roaming host='' target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just roaming "{{host}}" "{{target}}"
	conf=~/.ssh/dnf-roaming.conf
	mkdir -p ~/.ssh
	touch "$conf" && chmod 600 "$conf"
	if [ -z "{{host}}" ] ;then
		if [ -s "$conf" ] ;then
			cat "$conf"
		else
			just _info "No roaming redirection." "SSH"
		fi
		exit 0
	fi
	t=$(just _resolve "{{host}}" "{{target}}")
	[ "$t" != "{{host}}" ] || just _fail "{{host}} resolves to itself: nothing to redirect."
	just roaming-clear "{{host}}"

	# The user config is read before /etc/ssh/ssh_config, so this stanza would
	# shadow the fleet policy set there (core.nix): restate it, or a roaming
	# host that was just reinstalled would fail on a changed key.
	cat >> "$conf" <<-EOF
		Host {{host}}
		  HostName $t
		  StrictHostKeyChecking no
		  UserKnownHostsFile /dev/null
	EOF

	# The `Include` that pulls this file in is declared by home-manager
	# (`programs.ssh.includes`): on an admin host that predates it, the file is
	# written but ssh never reads it — better said than silently ignored.
	if [ "$(ssh -G "{{host}}" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')" != "$t" ] ;then
		just _warn "ssh does not read dnf-roaming.conf: re-apply this admin host, then retry."
	fi
	just _log "{{host}} redirected to $t." "SSH"

# Drop the roaming redirection of one host (or of all of them)
[group('install')]
roaming-clear host='':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just roaming-clear "{{host}}"
	conf=~/.ssh/dnf-roaming.conf
	[ -f "$conf" ] || exit 0
	if [ -z "{{host}}" ] ;then
		: > "$conf"
		just _log "All roaming redirections dropped." "SSH"
		exit 0
	fi

	# `skip` stays set until the next Host line, dropping the whole stanza.
	tmp=$(mktemp)
	awk -v h="{{host}}" '$1 == "Host" { skip = ($2 == h) } !skip' "$conf" > "$tmp"
	mv "$tmp" "$conf"
	chmod 600 "$conf"

# `target` is the network address to reach the node; 'auto' asks `_target`,
# which returns the host name in its own zone and the reserved roaming address
# elsewhere. The machine identity stays {{host}} whatever the address used.
#
# Copy pub key to the node (nix user must exist)
[group('install')]
copy-id host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	t=$(just _resolve "{{host}}" "{{target}}")
	if sudo -i -u nix ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o BatchMode=yes nix@"$t" "true"; then
		just _info "SSH key already exists for {{host}}, continue..." "SSH"
	else
		just _log "Copying id to {{host}} ($t)..." "SSH"

		# Restates the fleet policy (core.nix) rather than relying on it: a
		# recorded-then-changed key disables password auth, the very thing
		# ssh-copy-id needs to bootstrap a freshly installed node.
		sudo -i -u nix ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -f nix@"$t"
	fi
	just _log "Cleaning authorized_keys..." "SSH"
	sudo -i -u nix ssh nix@"$t" '[ -f ~/.ssh/authorized_keys ] && sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys || true'
	sudo -i -u nix ssh -o PasswordAuthentication=no -o PubkeyAuthentication=yes nix@"$t" 'echo "OK, it works!"'

	# Gateways pull TLS certs from the HCS over SSH as `nix` (sync-caddy-certs),
	# so they need the shared deploy PRIVATE key, not just authorized_keys.
	# Restrict it to gateways: admin hosts already hold it (configure-admin-host
	# generates it locally), any other host must never carry it.
	profile=$({{nix}} eval --impure --raw \
		--expr '(builtins.head (builtins.filter (h: h.hostname == "{{host}}") (import {{workDir}}/var/generated/hosts.nix))).profile' 2>/dev/null || echo "")
	if [ "$profile" = "gateway" ] ;then
		just _log "Pushing nix deploy key (gateway TLS cert sync)..." "SSH"
		sudo -i -u nix scp ~nix/.ssh/id_ed25519 ~nix/.ssh/id_ed25519.pub nix@"$t":.ssh/
		sudo -i -u nix ssh nix@"$t" 'chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519 && chmod 644 ~/.ssh/id_ed25519.pub'
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
		bash {{assetsDir}}/scripts/just-generate-secrets.sh)
	case "$n" in
		skip) ;;
		0) just _info "Secrets already generated." "SOPS" ;;
		*) just _log "$n secret(s) generated." "SOPS" ;;
	esac

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

# `target`: network address to reach the node ('auto' = resolved by `_target`).
# The extracted config is always stored under the machine identity {{host}}.
#
# Extract hardware config from host
[group('install')]
copy-hw host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	t=$(just _resolve "{{host}}" "{{target}}")
	just _log "Extracting hardware information..."
	mkdir -p usr/machines/{{host}}
	sudo -i -u nix ssh nix@"$t" "sudo nixos-generate-config --no-filesystems --show-hardware-config" > {{workDir}}/usr/machines/{{host}}/hardware-configuration.nix
	nixfmt -s usr/machines/{{host}}/hardware-configuration.nix

# `target`: network address to reach the node ('auto' = resolved by `_target`).
#
# Push the infrastructure key to the host
[group('install')]
push-key host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just push-key "{{host}}" "{{target}}"
	t=$(just _resolve "{{host}}" "{{target}}")
	just _check_infra_admin
	just _log "Pushing infra key file..." "SOPS"
	ssh nix@"$t" 'sudo mkdir -p {{sopsInfraTargetDir}}'
	ssh nix@"$t" 'sudo chown -R nix {{sopsInfraTargetDir}}'
	scp {{sopsInfraKeyFile}} nix@"$t":{{sopsInfraTargetFile}}
	ssh nix@"$t" 'sudo chown -R root {{sopsInfraTargetDir}}'
	ssh nix@"$t" 'sudo chmod 600 {{sopsInfraTargetFile}}'

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
	TARGET_HOST=$(just _resolve "{{host}}" "{{ip}}")
	just _log "We need to add, commit and build..."

	# Staged before the sops step on purpose: `_gen-secrets` evaluates the flake
	# to know which secrets the fleet needs, and nix only sees files git already
	# knows about — a brand new host would stay invisible to the very step that
	# must create its credentials.
	git add .
	just _log "Sops updates..."
	just _gen-secrets
	just _fix_fs_permissions
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
_host-info host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	t=$(just _resolve "{{host}}" "{{target}}")
	MAC_ADDR=`sudo -i -u nix ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -o PubkeyAuthentication=yes nix@"$t" "ip -o link show up | grep -v 'lo:' | head -n 1 | sed 's/^.* \([0-9a-f:]*\) brd .*$/\1/'"`
	just _log "You can register the mac address in etc/config.yaml: {{GREEN}}$MAC_ADDR{{NORMAL}}"

# Auto-switching here means the chained `copy-id` / `copy-hw` / `push-key`
# already inherit the nix user — their own guards short-circuit cleanly.
#
# `ip`: network address to reach the node ('auto' = resolved by `_target`).
# Configuring a host that sits outside its own zone also installs the ssh
# redirection, so the `apply` that follows reaches it instead of its home
# address; `just roaming-clear {{host}}` drops it once the host is back home.
#
# New host: ssh cp id, extr. hw, push infra key, clean, info
[group('install')]
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
	[ "$t" = "{{host}}" ] || just roaming "{{host}}" "$t"
	just _log "If no error occurs, do not forget to commit and apply:"
	just _log "git add . && git commit -m 'Installing new host {{host}}'"
	just _log "just apply-verbose {{host}}"
	just _host-info "{{host}}" "$t"

# One address for the whole run: `_target` gives the host name when it is
# installed at home, and the address its host zone reserves for it otherwise.
# The reservation is a DHCP one, keyed on the MAC, so the installer and the
# installed system land on the very same address — nothing to type, nothing to
# guess. Requires the local gateway to be up to date (`just apply <gateway>`)
# when the host has just been declared in etc/config.yaml.
#
# New host: full installation (install, configure, apply)
[group('install')]
full-install host user='nixos' ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	target=$(just _resolve "{{host}}" "{{ip}}")
	if [ "$target" != "{{host}}" ] ;then
		just _log "{{host}} sits outside its own zone, reachable at $target." "INSTALL"
	fi
	just install {{host}} {{user}} "$target"
	just _log "Waiting for reboot..."

	# nixos-anywhere returns while the installer still answers on ssh: watch the
	# machine go down before waiting for it to come back, or `configure` would
	# talk to a system about to vanish. Non-fatal — a fast reboot can be over
	# before the first poll.
	just _wait-ssh "$target" down 180 || true
	just _wait-ssh "$target" up
	just configure {{host}} "$target"
	just _log "Let's do that automatically..."
	#just _fix_fs_permissions
	just _log "Adding and committing (amend)..." "GIT"
	git add . && (git diff --cached --quiet || git commit --amend --no-edit --allow-empty) && git reset
	just apply-verbose {{host}}
	just _log "Cleaning new system..."
	just gc {{host}}
	just _log "Last reboot..."
	sudo -i -u nix colmena exec --config "{{workDir}}/flake.nix" --on "{{host}}" "nohup bash -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &"

	# The redirection was only meant to survive the install: from here the host
	# answers under its own name, at home or wherever it is next plugged in.
	just roaming-clear "{{host}}"
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

# With the key plugged into this admin host (~3 touches), captures:
#   - the pam_u2f credential -> usr/secrets/yubikeys.json (public, committed):
#     a touch replaces the session password on every host of the user;
#   - a FIDO2 hmac-secret credential -> derived secret in sops: encrypted
#     hosts self-enroll their LUKS headers at next apply (no key needed there).
# Sets a FIDO2 PIN beforehand if the key has none: Kanidm passkeys require
# user verification (PAM and LUKS never request UV, they stay touch-only).
# Ensures the shared `luks-passphrase` sops secret exists (authorizes keyslot
# management on hosts), then prints the Kanidm passkey procedure (WebAuthn is
# an interactive web ceremony by design; Vaultwarden 2FA is self-service).
# `action=revoke` removes the (user, key) everywhere at next apply.
#
# Re-running is idempotent: the plugged key is identity-checked (silent FIDO2
# assertion against the registered credId). Same key = nothing to do; different
# key = full replacement, the old credential is pruned fleet-wide at next apply
# (old Kanidm/Vaultwarden passkeys must be removed by hand). Requires exactly
# ONE plugged key: with several, each capture could target a different device.
#
# YubiKey enrollment: ONE physical enrollment per (user, key), fleet-wide.
[group('install')]
yubikey user key='main' action='enroll':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just yubikey "{{user}}" "{{key}}" "{{action}}"
	registry={{secretsDir}}/yubikeys.json
	case "{{key}}" in main|backup) ;; *) just _fail "key must be 'main' or 'backup'" ;; esac
	yq -e '.users."{{user}}"' {{workDir}}/etc/config.yaml >/dev/null 2>&1 \
		|| just _fail "Unknown user '{{user}}' (see etc/config.yaml)."
	[ -f {{sopsSecretsFile}} ] || just _fail "No sops secrets file: run 'just configure-admin-host' first."
	just _sops_before_edit
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}

	# Revocation is declarative: dropping the registry entry + the sops secret
	# removes the PAM credential and prunes the LUKS keyslots at next apply.
	if [ "{{action}}" = "revoke" ] ;then
		[ -f "$registry" ] || just _fail "No registry ($registry)."
		yq -i -p=json -o=json 'del(."{{user}}"."{{key}}")' "$registry"
		yq -i -p=json -o=json 'del(."{{user}}" | select(length == 0))' "$registry"
		sops unset {{sopsSecretsFile}} '["yubikey"]["{{user}}"]["{{key}}"]' || true
		just _fix_fs_permissions
		just _log "Revoked {{user}}/{{key}}. Commit and 'just apply' to propagate." "YUBIKEY"
		exit 0
	fi
	[ "{{action}}" = "enroll" ] || just _fail "Unknown action '{{action}}' — valid: enroll, revoke"
	domain=$(yq -r '.network.domain' {{workDir}}/etc/config.yaml)
	origin="pam://$domain"

	# FIDO2 tools come from a transient nix shell (nothing to install first)
	# and run as root (direct hidraw access to the key).
	fido() { sudo {{nix}} shell nixpkgs#pam_u2f nixpkgs#libfido2 --command "$@" ; }

	# Exactly one plugged key: with several, pamu2fcfg and fido2-* each pick
	# their own device and can silently capture the wrong key.
	devs=$(fido fido2-token -L | cut -d: -f1)
	[ -n "$devs" ] || just _fail "No FIDO2 key detected: plug the '{{key}}' YubiKey of {{user}}."
	[ "$(printf '%s\n' "$devs" | wc -l)" = 1 ] \
		|| just _fail "Several FIDO2 keys detected: plug only the '{{key}}' YubiKey of {{user}}."
	dev=$devs

	# Physical identity check: a credId only asserts on the key that minted it
	# (up=false: silent, no touch nor PIN). Same key + intact sops secret =
	# idempotent no-op; a key already enrolled under the other name is refused;
	# any other mismatch (new or factory-reset key) = full replacement below.
	assert_ok() {
		printf '%s\n%s\n%s\n' "$(openssl rand -base64 32)" io.systemd.cryptsetup "$1" \
			| fido fido2-assert -G -t up=false "$dev" >/dev/null 2>&1
	}
	if [ -f "$registry" ] ;then
		for kname in main backup ;do
			cred=$(yq -r ".\"{{user}}\".\"$kname\".credId // \"\"" "$registry")
			[ -n "$cred" ] || continue
			if assert_ok "$cred" ;then
				[ "$kname" = "{{key}}" ] \
					|| just _fail "This physical key is already enrolled as {{user}}/$kname."
				if sops -d --extract '["yubikey"]["{{user}}"]["{{key}}"]["luks-secret"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
					just _fix_fs_permissions
					just _log "This key is already enrolled as {{user}}/{{key}}: nothing to do." "YUBIKEY"
					exit 0
				fi
				just _log "Registry entry intact but sops secret missing: re-enrolling." "YUBIKEY"
			elif [ "$kname" = "{{key}}" ] ;then
				just _warn "Different physical key: replacing {{user}}/{{key}} (old credential pruned at next apply; remove old Kanidm/Vaultwarden passkeys by hand)."
			fi
		done
	fi

	# Kanidm passkeys need WebAuthn user verification, which the key satisfies
	# with its FIDO2 PIN: create it if missing. Once set, the captures below
	# prompt for it (CTAP2 requires PIN auth to mint credentials).
	if fido fido2-token -I "$dev" | grep -q noclientPin ;then
		just _log "Kanidm (WebAuthn) requires a FIDO2 PIN and this key has none: set it now." "YUBIKEY"
		fido fido2-token -S "$dev"
	fi

	# Fixed origin/appid: one PAM credential is valid on the whole fleet.
	just _log "PAM credential: touch the key..." "YUBIKEY"
	pamline=$(fido pamu2fcfg -u "{{user}}" -o "$origin" -i "$origin")
	pamcred="${pamline#*:}"
	[ -n "$pamcred" ] || just _fail "pamu2fcfg failed."

	# LUKS: non-discoverable hmac-secret credential bound to the
	# systemd-cryptsetup relying party. The derived secret (HMAC of a fixed
	# salt) is only reproducible with the physical key; it goes to sops and
	# becomes the keyslot passphrase on every encrypted host of the user.
	just _log "LUKS credential: touch the key..." "YUBIKEY"
	cred=$(printf '%s\n%s\n%s\n%s\n' "$(openssl rand -base64 32)" io.systemd.cryptsetup "{{user}}" \
		"$(openssl rand -base64 16)" | fido fido2-cred -M -h "$dev")
	credid=$(printf '%s\n' "$cred" | sed -n 5p)
	salt=$(openssl rand -base64 32)
	just _log "LUKS secret derivation: touch the key..." "YUBIKEY"
	secret=$(printf '%s\n%s\n%s\n%s\n' "$(openssl rand -base64 32)" io.systemd.cryptsetup "$credid" "$salt" \
		| fido fido2-assert -G -h "$dev" | sed -n 5p)
	{ [ -n "$credid" ] && [ -n "$secret" ] ; } || just _fail "FIDO2 hmac-secret capture failed."

	# Shared LUKS install passphrase: asked once (only if missing from sops),
	# hosts use it to authorize new keyslots. Never displayed nor stored in clear.
	if ! sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
		echo -n "LUKS passphrase typed at hosts install (disko): "
		read -s LP ; echo
		[ -n "$LP" ] || just _fail "Empty passphrase."
		sops set {{sopsSecretsFile}} '["luks-passphrase"]' "\"$LP\""
	fi
	sops set {{sopsSecretsFile}} '["yubikey"]["{{user}}"]["{{key}}"]["luks-secret"]' "\"$secret\""

	# Public registry consumed by dnf/modules/system/yubikey.nix.
	[ -f "$registry" ] || echo '{}' > "$registry"
	PAM="$pamcred" CID="$credid" SALT="$salt" yq -i -p=json -o=json \
		'."{{user}}"."{{key}}" = {"pam": strenv(PAM), "credId": strenv(CID), "salt": strenv(SALT)}' "$registry"
	just _fix_fs_permissions
	just _log "Enrolled {{user}}/{{key}}." "YUBIKEY"
	just _log "Now: git add usr/secrets/yubikeys.json && just commit ... && just apply" "YUBIKEY"

	# Kanidm passkey: interactive web ceremony (once for the whole SSO). Mint
	# the reset link now if possible, else print the manual procedure.
	if [ "$(yq -r '.network.coordination.enable' {{workDir}}/etc/config.yaml)" = "true" ] ;then
		hcs=$(yq -r '.network.coordination.hostname' {{workDir}}/etc/config.yaml)
		just _log "Kanidm reset link for the passkey (idm_admin login):" "YUBIKEY"
		ssh -t nix@"$hcs" "kanidm person credential create-reset-token {{user}} --name idm_admin" \
			|| just _warn "Token not created — run: just enter $hcs ; kanidm person credential create-reset-token {{user}} --name idm_admin"
		just _info "Web ceremony: refuse the password-manager popup (Bitwarden/KeePassXC), the passkey must land on the physical key (FIDO2 PIN + touch)." "YUBIKEY"
	fi
	just _info "Vaultwarden: add the key in the web vault (Settings > Security > Two-step login, WebAuthn)." "YUBIKEY"

# LUKS provisioning: per-host passphrase + remote unlock. Fully idempotent
# (safe from `just configure`); a host without LUKS volume is a logged no-op.
# Each run converges, prompting only for what is missing:
#
# - sops: shared `luks-passphrase` + per-host `luks/<host>/passphrase`
#   (created if missing; rotated ONLY with the 'passwd' action);
# - public manifest usr/secrets/luks.json (committed): registers the host for
#   dnf/modules/system/luks.nix and records the gateway WAN IP so
#   `just enter` still finds the initrd sshd when the VPN is down;
# - on the target: initrd SSH host key (must exist before the bootloader of
#   the next apply embeds it), and a valid shared keyslot — a host installed
#   with a different passphrase gets its shared slot bootstrapped here, the
#   install passphrase is asked once.
#
# LUKS provisioning: per-host passphrase + remote unlock (idempotent)
[group('install')]
luks host action='' ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just luks "{{host}}" "{{action}}" "{{ip}}"
	case "{{action}}" in ''|passwd) ;; *) just _fail "Unknown action '{{action}}' — valid: passwd" ;; esac
	manifest={{secretsDir}}/luks.json
	target=$(just _resolve "{{host}}" "{{ip}}")
	yq -e '.hosts[] | select(.hostname == "{{host}}")' {{workDir}}/etc/config.yaml >/dev/null 2>&1 \
		|| just _fail "Unknown host '{{host}}' (see etc/config.yaml)."

	# No LUKS = no-op: keeps the recipe safely callable from `just configure`.
	if ! grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/disko.nix 2>/dev/null ;then
		just _log "No LUKS volume on {{host}}: nothing to do." "LUKS"
		exit 0
	fi
	[ -f {{sopsSecretsFile}} ] || just _fail "No sops secrets file: run 'just configure-admin-host' first."
	just _sops_before_edit
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}

	# Shared passphrase: asked once fleet-wide (same slot `just yubikey` uses
	# to authorize keyslot management).
	if ! sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
		echo -n "Shared LUKS passphrase (unlocks every encrypted host): "
		read -s LP ; echo
		[ -n "$LP" ] || just _fail "Empty passphrase."
		sops set {{sopsSecretsFile}} '["luks-passphrase"]' "\"$LP\""
	fi

	# Per-host passphrase: created once, rotated only on explicit 'passwd'.
	# Empty input degrades to a strong random value: the host stays
	# unlockable via the shared passphrase and the YubiKeys anyway.
	if [ "{{action}}" = "passwd" ] \
		|| ! sops -d --extract '["luks"]["{{host}}"]["passphrase"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
		echo -n "LUKS passphrase for {{host}} (empty = random): "
		read -s PP ; echo
		if [ -n "$PP" ]; then
			echo -n "Confirm: "
			read -s PP2 ; echo
			[ "$PP" = "$PP2" ] || just _fail "Passphrases do not match."
		else
			PP=$(openssl rand -base64 32)
			just _log "Random passphrase generated (kept in sops only)." "LUKS"
		fi
		sops set {{sopsSecretsFile}} '["luks"]["{{host}}"]["passphrase"]' "\"$PP\""
	else
		just _log "Per-host passphrase already in sops (rotate with 'just luks {{host}} passwd')." "LUKS"
	fi

	# Public manifest consumed by dnf/modules/system/luks.nix. Entry created
	# once; existing fields (recorded wan IP) are preserved.
	[ -f "$manifest" ] || echo '{}' > "$manifest"
	yq -e '."{{host}}"' "$manifest" >/dev/null 2>&1 \
		|| yq -i -p=json -o=json '."{{host}}" = {}' "$manifest"
	just _fix_fs_permissions

	# Everything below converges the target itself; a sleeping host only
	# needs a re-run before its next apply (the initrd host key must exist
	# there when the bootloader embeds it).
	if ! ssh -o ConnectTimeout=5 nix@"$target" true 2>/dev/null ;then
		just _warn "{{host}} unreachable at $target: re-run 'just luks {{host}}' once it is up, BEFORE any apply."
		exit 0
	fi
	ssh nix@"$target" 'sudo mkdir -p /var/lib/luks-initrd \
		&& { sudo test -s /var/lib/luks-initrd/ssh_host_ed25519_key \
		|| sudo ssh-keygen -t ed25519 -N "" -q -f /var/lib/luks-initrd/ssh_host_ed25519_key ; }'

	# Gateways: record the current WAN IP. The VPN route to a zone dies with
	# its gateway, so `just enter` falls back to this address to reach the
	# initrd sshd. Refreshed at each run (ISP renumbering needs a re-run).
	# The gateway hostname comes from var/generated/network.nix (same source
	# as the luks module): the raw config.yaml does not carry it, the
	# generator derives it from the host profiles.
	# NB: the parentheses + explicit `| .zone` matter — `select(...).zone`
	# makes yq emit one empty line per non-matching host, corrupting $zone.
	zone=$(yq -r '(.hosts[] | select(.hostname == "{{host}}") | .zone) // ""' {{workDir}}/etc/config.yaml)
	zone="${zone%%:*}"
	wanif=$(yq -r ".zones.\"$zone\".gateway.wan.interface // \"\"" {{workDir}}/etc/config.yaml)
	gwhost=$({{nix}} eval --impure --raw \
		--expr "(import {{workDir}}/var/generated/network.nix).zones.\"$zone\".gateway.hostname or \"\"" 2>/dev/null || echo "")
	if [ -n "$wanif" ] && [ "$gwhost" = "{{host}}" ] ;then
		wan=$(ssh nix@"$target" "ip -4 -o addr show dev '$wanif' scope global" 2>/dev/null \
			| awk '{print $4}' | cut -d/ -f1 | head -1)
		if [ -n "$wan" ] ;then
			# The earlier _fix_fs_permissions restored usr/secrets/ ownership:
			# reopen it for the manifest write, restore right after.
			just _sops_before_edit
			WAN="$wan" yq -i -p=json -o=json '."{{host}}".wan = strenv(WAN)' "$manifest"
			just _fix_fs_permissions
			just _log "WAN IP of {{host}} recorded: $wan" "LUKS"
		fi
	fi

	# Keyslot bootstrap: the sync/enroll units can only authorize keyslot
	# operations with a managed passphrase. A volume that accepts none of
	# them (host installed with another passphrase) gets its shared slot
	# added here, authorized by the install passphrase.
	SHARED=$(sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}})
	PERHOST=$(sops -d --extract '["luks"]["{{host}}"]["passphrase"]' {{sopsSecretsFile}})
	test_slot() { printf '%s' "$1" | ssh nix@"$target" "sudo cryptsetup open --test-passphrase --key-file=- '$2'" >/dev/null 2>&1 ; }

	# Trailing `exit 0`: a `for` loop reports its LAST iteration, so the probe
	# failed whenever the final by-partlabel entry was not LUKS — devs was
	# correct, but `set -e` killed the recipe on the assignment. An ssh or sudo
	# failure still surfaces: the snippet never runs in that case.
	devs=$(echo 'for p in /dev/disk/by-partlabel/*; do cryptsetup isLuks --type luks2 "$p" 2>/dev/null && echo "$p"; done; exit 0' \
		| ssh nix@"$target" sudo bash -s)
	[ -n "$devs" ] || just _fail "No LUKS2 volume found on {{host}} (disko config out of sync?)."
	fixed=""
	for dev in $devs ;do
		if test_slot "$SHARED" "$dev" || test_slot "$PERHOST" "$dev" ;then
			just _log "$dev already accepts a managed passphrase." "LUKS"
			continue
		fi
		if [ -z "${INSTALL:-}" ] ;then
			echo -n "Install passphrase of {{host}} (typed at disko install): "
			read -s INSTALL ; echo
			[ -n "$INSTALL" ] || just _fail "Empty passphrase."
		fi

		# Old key on stdin, new key via a root-only tmpfs file, both wiped.
		printf '%s\n%s\n' "$INSTALL" "$SHARED" | ssh nix@"$target" "sudo bash -c 'IFS= read -r cur; IFS= read -r new; t=\$(mktemp -p /run); chmod 600 \"\$t\"; printf %s \"\$new\" >\"\$t\"; rc=0; printf %s \"\$cur\" | cryptsetup luksAddKey --key-file=- $dev \"\$t\" >/dev/null 2>&1 || rc=1; rm -f \"\$t\"; exit \$rc'" \
			|| just _fail "luksAddKey failed on $dev (wrong install passphrase?)."
		just _log "Shared keyslot bootstrapped on $dev." "LUKS"
		fixed=1
	done

	# A bootstrap unlocks the sync/enroll units: re-run them now so the
	# per-host slot and the FIDO2 tokens land without waiting for a reboot.
	if [ -n "$fixed" ] ;then
		ssh nix@"$target" 'sudo systemctl restart luks-passphrase-sync.service yubikey-luks-enroll.service' \
			|| just _warn "Sync units not deployed yet: run 'just apply {{host}}' to converge."
	fi
	for dev in $devs ;do
		tokens=$(echo "cryptsetup luksDump $dev" | ssh nix@"$target" sudo bash -s | grep -c 'systemd-fido2' || true)
		just _log "$dev: $tokens FIDO2 token(s) enrolled." "LUKS"
	done
	just _log "Provisioned {{host}}." "LUKS"
	just _log "If luks.json changed: git add usr/secrets/luks.json && just commit ... && just apply {{host}}" "LUKS"

# Edit sops secrets
[group('install')]
sops:
	#!/usr/bin/env bash
	set -euo pipefail
	just _sops_before_edit
	sudo -i -u nix EDITOR=vim sops {{sopsSecretsFile}} || true
	just _fix_fs_permissions

# Provision the Matrix alert bot + rooms (idempotent) from network.matrix.
# Reads config.yaml (network.matrix.{admin,bot}), creates/refreshes the bot,
# webhook secret and the warnings/incidents rooms, and writes the resulting
# room IDs back into config.yaml. Re-run any time; it only fixes what's missing.
#
# Provision the Matrix alert bot and its rooms (idempotent)
[group('install')]
configure-alert-bot:
	#!/usr/bin/env bash
	set -euo pipefail
	WORKDIR="{{workDir}}" bash {{assetsDir}}/scripts/just-configure-alert-bot.sh
	just _fix_fs_permissions

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
#
# Sync Kanidm replication certificates (multi-zone read-only replicas).
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

# Read-only "doctor": never wipes, restarts or applies anything. Pass the supplier
# (the HCS / coordination host) and the comma-separated consumer gateways, e.g.
#   just idm-fix-replica hcs agate,gw
# The usual blocker is dangling references in the supplier database that make the
# replication refresh fail (post_repl_refresh referential-integrity check). This
# checks supplier integrity, certificate sync and each consumer's last refresh,
# then prints a copy-pasteable checklist. Same SSH/identity conventions as
# idm-sync-certs (only the per-node SSH uses the nix deploy user).
#
# Diagnose Kanidm replication health and prescribe the exact remediation steps.
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
# Central build by default (see `buildOnTarget`): the deployer builds every
# closure once and harmonia shares it across the fleet. Set `buildOnTarget=1`
# to restore per-target builds. Ref: https://nixos.wiki/wiki/Binary_Cache

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

# Apply force with verbose options
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

#==============================================================================
# Maintenance
#==============================================================================
#
# Same auto-switch pattern as the apply group: each recipe re-execs itself
# under the `nix` user when the caller is somebody else.

# When the host answers on port 22, plain ssh as usual. Otherwise it may be
# waiting in initrd for its LUKS passphrase, where sshd listens on port 2222
# (dnf/modules/system/luks.nix): probe the explicit ip (if given), the
# hostname, then the WAN IP recorded in usr/secrets/luks.json — the VPN
# route to a zone dies with its gateway, only the WAN side remains. On the
# first hit, log in as root with the nix deploy key and answer the pending
# passphrase prompt. The initrd has its own host key, regenerated by every
# reinstall, and the login is root@ — outside the `Match user nix` fleet
# policy (core.nix), so the same "never pin" options are restated here.
#
# Interactive shell to the host.
[group('manage')]
enter on ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	target="{{on}}" ; [ "{{ip}}" = "auto" ] || target="{{ip}}"
	if timeout 2 bash -c "exec 3<>/dev/tcp/$target/22" 2>/dev/null ;then
		just _log "Entering {{on}}..." "SSH"
		if [ "${USER:-}" = "nix" ]; then
			exec ssh nix@"$target"
		else
			exec sudo -i -u nix ssh nix@"$target"
		fi
	fi

	# Port 22 is down: look for an initrd sshd on every known address.
	candidates="$target"
	[ "$target" = "{{on}}" ] || candidates="$candidates {{on}}"
	wan=$(yq -r '."{{on}}".wan // ""' {{secretsDir}}/luks.json 2>/dev/null || true)
	{ [ -z "$wan" ] || [ "$wan" = "$target" ] ; } || candidates="$candidates $wan"
	for c in $candidates ;do
		if timeout 2 bash -c "exec 3<>/dev/tcp/$c/2222" 2>/dev/null ;then
			just _log "{{on}} ($c) is waiting in initrd: answering the LUKS prompt..." "SSH"
			if [ "${USER:-}" = "nix" ]; then
				exec ssh -t -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$c" \
					systemd-tty-ask-password-agent --query --watch
			else
				exec sudo -i -u nix ssh -t -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$c" \
					systemd-tty-ask-password-agent --query --watch
			fi
		fi
	done
	just _fail "{{on}} unreachable on ports 22 and 2222 (tried: $candidates)."

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

# Attaches to the graphical session already open on the host; it never creates
# one, so nobody logged in means nothing to do.
#
# `ro` (default) watches, `rw` takes control. Both are enforced by the remote
# server, never by the client. Nothing is ever exposed on the network: the RDP
# listener is armed for the length of the session and reached through an ssh
# tunnel, so the fleet's deny-by-default firewall is left alone.
#
# Deliberately NOT re-exec'd as nix like its neighbours: only the ssh side runs
# as nix, because the FreeRDP window has to reach the caller's own Wayland
# display and nix cannot.
#
# Remote desktop on a graphical host (ro = view only, rw = control).
[group('manage')]
remote-desktop host mode='ro':
	#!/usr/bin/env bash
	set -euo pipefail
	case "{{mode}}" in
		ro | rw) ;;
		*) just _fail "mode must be 'ro' or 'rw'." ;;
	esac
	target=$(just _target "{{host}}")
	rssh() { sudo -i -u nix ssh -o ConnectTimeout=5 nix@"$target" "$@" ; }

	# Pinned to the same nixpkgs as the fleet, so the client never depends on
	# what happens to be installed on the machine running just.
	just _log "Resolving the RDP client..." "RDP"
	client=$({{nix}} build --no-link --print-out-paths --impure --expr \
		'let f = builtins.getFlake "{{workDir}}/dnf"; in f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.freerdp')/bin/sdl-freerdp

	just _log "Arming a {{mode}} session on {{host}} ($target)..." "RDP"
	params=$(rssh sudo dnf-remote-desktop start "{{mode}}") \
		|| just _fail "could not arm a session on {{host}}: is anyone logged in, and is the remote-desktop service enabled there?"
	get() { printf '%s\n' "$params" | sed -n "s/^$1=//p" | head -n1 ; }

	# The remote port is fixed by the port registry; the local one only has to
	# be free here.
	lport=3389
	while timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$lport" 2>/dev/null ;do
		lport=$((lport + 1))
	done
	ctl=$(mktemp -u /tmp/dnf-rd-XXXXXXXX)

	# Client closed, ctrl-c or failure: the host disarms and the tunnel goes.
	# The host keeps its own timeout as a last resort if this machine dies.
	cleanup() {
		sudo -i -u nix ssh -S "$ctl" -O exit nix@"$target" 2>/dev/null || true
		rssh sudo dnf-remote-desktop stop >/dev/null 2>&1 || true
	}
	trap cleanup EXIT

	sudo -i -u nix ssh -M -S "$ctl" -f -N -o ExitOnForwardFailure=yes \
		-L "127.0.0.1:$lport:127.0.0.1:$(get port)" nix@"$target"
	just _log "$(get backend) session of $(get session_user), closing itself in $(get timeout) min." "RDP"

	# Arguments through a pipe rather than argv: the password stays out of ps.
	"$client" /args-from:fd:3 3< <(
		echo "/v:127.0.0.1:$lport"
		echo "/t:{{host}} ({{mode}})"
		echo "/gfx:AVC444"
		echo "/network:lan"

		# Mirroring a physical monitor, the server cannot resize anything, so
		# `+dynamic-resolution` would leave the client showing the top-left
		# crop of a desktop larger than its default 1024x768 window. The
		# client has to adapt instead. Opening at the REMOTE resolution maps
		# one pixel to one pixel: right aspect ratio, and no resampling blur.
		# Fullscreen is then exact whenever both screens match. Smart-sizing
		# still follows every manual resize. Falling back to a share of the
		# local screen when the host could not report its geometry costs the
		# aspect ratio, not the session.
		geom=$(get geometry)
		if [ -n "$geom" ] ;then
			echo "/size:$geom"
		else
			echo "/size:100%"
		fi
		echo "/smart-sizing"
		if [ "$(get auth)" = credentials ] ;then
			echo "/u:$(get username)"
			echo "/p:$(get password)"
			echo "/cert:fingerprint:sha256:$(get fingerprint)"
		else

			# freerdp-shadow-cli mints its own certificate and runs with client
			# authentication off: on that branch trust comes from the tunnel,
			# not from RDP.
			echo "/sec:tls"
			echo "/cert:ignore"
		fi
	)

# Run all checks and tests (useful before deploy)
[group('check')]
check-all:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ -d {{workDir}}/dnf ] ;then
		just _log "DNF Unit Tests" "CHECK-ALL"
		cd {{workDir}}/dnf && just unit-tests | grep -v '✅'
	fi
	just _log "Network flake" "CHECK-ALL"
	cd {{workDir}} && just check-flake
