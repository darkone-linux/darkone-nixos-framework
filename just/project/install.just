# DNF just — installation: new hosts, installer ISO.

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

		# No bootstrap left to attempt: core.nix disables password and
		# keyboard-interactive auth and drops `~/.ssh/authorized_keys`, so
		# ssh-copy-id has neither a way in nor a file sshd would read. The
		# deploy key is declarative (`usr/secrets/nix.pub`).
		just _fail "nix@{{host}} ($t) refuses the deploy key. Check usr/secrets/nix.pub, then re-apply from a channel that still works (console, initrd sshd on 2222)."
	fi

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
	scp {{sopsInfraKeyFile}} nix@"$t":{{sopsInfraTargetFile}} > /dev/null
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

	# A run that died between `configure` and its final cleanup leaves this host
	# redirected to an install-time address, host key checking disabled, for
	# every later ssh and colmena. Start from a clean slate.
	just roaming-clear "{{host}}"
	just clean
	just _log "Preparation..."
	if [ ! -f "./usr/machines/{{host}}/default.nix" ]; then
		just _fail "Host '{{host}}' not found. Check it exists and has a disko config in etc/config.yaml."
	fi
	echo "{ }" > ./usr/machines/{{host}}/hardware-configuration.nix

	# The install ends on a reboot, and the rest of the chain has to find the
	# machine again. dnsmasq keys its reservation on the MAC and DNS publishes
	# the fixed address of the host's zone: without both, the installed system
	# takes a random lease and everything after this points at nothing.
	hostconf=$(just _host_conf "{{host}}")
	mac=$(echo "$hostconf" | yq -p=json -r '.mac // ""')
	zonespec=$(echo "$hostconf" | yq -p=json -r '.zone // ""')
	extip=$(echo "$hostconf" | yq -p=json -r '.ipv4.external // ""')

	# Only where a gateway actually serves the zone: the very first host of a
	# network has nothing to reserve an address for it, and is installed on an
	# address given by hand.
	zonegw=$({{nix}} eval --impure --raw \
		--expr "(import {{workDir}}/var/generated/network.nix).zones.\"${zonespec%%:*}\".gateway.hostname or \"\"" 2>/dev/null || echo "")
	if [ -z "$extip" ] && [ -n "$zonegw" ] ;then
		if [ -z "$mac" ] ;then
			just _err "{{host}} has no 'mac:' in etc/config.yaml: no DHCP reservation, so it will"
			just _err "come back on a random address after the reboot that ends the install."
			just _err "Boot the installer, then: just host-info {{host}} <its-current-ip>"
			just _fail "Declare mac + a fixed 'zone: <zone>:<x.y>', then 'just apply $zonegw'."
		fi
		case "$zonespec" in
			*:*) ;;
			*) just _fail "{{host}} has no fixed address: use 'zone: <zone>:<x.y>' in etc/config.yaml, then 'just apply $zonegw'." ;;
		esac
	elif [ -z "$extip" ] && [ -z "$mac" ] ;then
		just _warn "No gateway in zone '${zonespec%%:*}': {{host}} keeps whatever address it was given."
	fi

	TARGET_HOST=$(just _resolve "{{host}}" "{{ip}}")

	# nixos-anywhere pins --target-host for the whole run and has no option to
	# follow a renumbering (only a port change, --post-kexec-ssh-port). So the
	# address must already be one the machine will KEEP: installing over an OS
	# still holding an older dynamic lease strands the run the moment the
	# installer re-runs DHCP and lands on the reserved address.
	#
	# `_candidates` without an explicit ip lists exactly the addresses the host
	# legitimately answers on — its own, its roaming reservation, its name — so
	# a host installed while visiting another zone still passes.
	if [ -n "$zonegw" ] ;then
		expected=$(just _candidates "{{host}}")
		if ! printf '%s\n' "$expected" | grep -qx -- "$TARGET_HOST" ;then
			just _err "Installing {{host}} on $TARGET_HOST, which is not an address it keeps."
			just _err "The installer re-runs DHCP and will move to its reservation mid-install,"
			just _err "leaving nixos-anywhere talking to nothing. Expected: $(echo $expected)."
			just _fail "Put the machine on its reserved address first (reboot it), then install there."
		fi
	fi
	just _log "We need to add, commit and build..."

	# Offline half of the LUKS provisioning, BEFORE the build: the module only
	# wakes up for a host listed in usr/secrets/luks.json, and the initrd host
	# key it needs must exist in sops so `--extra-files` can stage it below.
	# No-op on an unencrypted host.
	just luks "{{host}}" pre

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

		# nixos-anywhere refuses --vm-test together with --extra-files or
		# --disk-encryption-keys, so this mode exercises neither the staged
		# secrets nor the LUKS format key.
		if grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/disko.nix 2>/dev/null ;then
			just _warn "vm-test cannot supply the LUKS format key: disko will fail on {{host}}."
		fi
		{{nix}} run github:nix-community/nixos-anywhere -- --flake .#{{host}} --vm-test
	elif [ "{{do}}" == "install" ] ;then
		NIX_HOME=$(getent passwd nix | cut -d: -f6)
		mkdir -p {{workDir}}/usr/machines/{{host}}
		sudo chown -R nix {{workDir}}/usr/machines/{{host}}
		sudo chown -R nix /etc/nixos/.git

		# Everything the FIRST boot needs, staged into /mnt before nixos-install
		# runs. nixos-anywhere untars it as root with --no-same-owner, so modes
		# are what matters here, not ownership. Lives in /run: never on disk.
		stage=$(sudo mktemp -d -p /run dnf-extra-XXXXXX)
		pwfile=$(sudo mktemp -p /run dnf-luks-XXXXXX)
		trap 'sudo rm -rf "$stage" "$pwfile"' EXIT
		sudo chown nix "$stage" "$pwfile"
		sudo chmod 700 "$stage" ; sudo chmod 600 "$pwfile"

		# sops age key: without it the first activation decrypts nothing —
		# `just push-key` only runs later, at `just configure`.
		sudo install -D -m 600 {{sopsInfraKeyFile}} "$stage{{sopsInfraTargetFile}}"
		sudo chown -R nix "$stage"

		naflags=()
		if grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/disko.nix 2>/dev/null ;then

			# The initrd host key must be on the disk before nixos-install
			# embeds it in the bootloader: that is what makes the very first
			# boot answer on 2222 (dnf/modules/system/luks.nix). base64 in sops
			# so the key round-trips byte for byte.
			sudo -u nix mkdir -p "$stage/var/lib/luks-initrd"
			sudo -u nix env SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
				sops -d --extract '["luks"]["{{host}}"]["initrd-key"]' {{sopsSecretsFile}} \
				| base64 -d | sudo -u nix tee "$stage/var/lib/luks-initrd/ssh_host_ed25519_key" >/dev/null
			sudo -u nix env SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
				sops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' {{sopsSecretsFile}} \
				| sudo -u nix tee "$stage/var/lib/luks-initrd/ssh_host_ed25519_key.pub" >/dev/null
			sudo chmod 700 "$stage/var/lib/luks-initrd"
			sudo chmod 600 "$stage/var/lib/luks-initrd/ssh_host_ed25519_key"
			sudo chmod 644 "$stage/var/lib/luks-initrd/ssh_host_ed25519_key.pub"

			# disko formats with the shared fleet passphrase (passwordFile in
			# dnf/hosts/disko/luks-*.nix), so the format keyslot IS the shared
			# keyslot: nothing to type here, nothing to retype at `just luks`.
			# Piped, never captured: `$(...)` would eat a trailing byte and
			# cryptsetup compares raw file contents.
			sudo -u nix env SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
				sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} \
				| sudo -u nix tee "$pwfile" >/dev/null
			[ -s "$pwfile" ] || just _fail "Empty shared LUKS passphrase in sops."
			naflags+=(--disk-encryption-keys /tmp/dnf-luks.key "$pwfile")
		fi

		sudo -i -u nix {{nix}} run github:nix-community/nixos-anywhere -- \
			--copy-host-keys \
			--flake "{{workDir}}#{{host}}" \
			-i "${NIX_HOME}/.ssh/id_ed25519" \
			--extra-files "$stage" \
			"${naflags[@]}" \
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

	# Local counterpart of `install`'s --disk-encryption-keys: disko reads the
	# shared fleet passphrase from the path its `passwordFile` names, so the
	# format keyslot is the managed one. Piped, never captured: cryptsetup
	# compares raw file contents. No-op on an unencrypted layout.
	if grep -q '"luks"' ./usr/machines/{{host}}/disko.nix 2>/dev/null ;then
		trap 'sudo rm -f /tmp/dnf-luks.key' EXIT
		SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
			sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} \
			| sudo tee /tmp/dnf-luks.key >/dev/null
		sudo chmod 600 /tmp/dnf-luks.key
		[ -s /tmp/dnf-luks.key ] || just _fail "Empty shared LUKS passphrase in sops."
	fi
	sudo {{nix}} run github:nix-community/disko -- \
	  --mode disko \
	  --root-mountpoint {{dnfInstallDir}} ./usr/machines/{{host}}/disko.nix
	just _log "NixOS DNF installation..."
	sudo nixos-install --flake '.#{{host}}' --root {{dnfInstallDir}} --no-root-password
	just _log "Unmounting new system..."
	sudo umount -R {{dnfInstallDir}}
	sudo rmdir {{dnfInstallDir}}
	just _log "End of key installation"

# Read the MAC of a machine so it can be declared before being installed.
#
# `target` is usually the dynamic lease the installer picked up: a host with no
# `mac:` yet has no reservation, so it cannot be reached by name. Declare the
# address it prints, give the host a fixed `zone: "<zone>:<x.y>"` outside the
# DHCP pool, then `just apply <gateway>` — from there the installer and the
# installed system land on the very same address.
#
# Show the mac address of a host (to declare it in etc/config.yaml)
[group('install')]
host-info host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	t=$(just _resolve "{{host}}" "{{target}}")
	probe="ip -o link show up | grep -v 'lo:' | head -n 1 | sed 's/^.* \([0-9a-f:]*\) brd .*$/\1/'"

	# `nixos` on purpose: the very machine whose MAC is still unknown is the one
	# running the DNF installer image, where the account is `nixos`, not `nix`.
	MAC_ADDR=""
	for u in nix nixos ;do
		MAC_ADDR=$(sudo -i -u nix ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			-o PasswordAuthentication=no -o PubkeyAuthentication=yes -o ConnectTimeout=5 \
			"$u"@"$t" "$probe" 2>/dev/null || true)
		[ -z "$MAC_ADDR" ] || break
	done
	[ -n "$MAC_ADDR" ] || just _fail "Could not read a MAC from $t (tried nix@ and nixos@)."
	just _log "Mac address (to register in etc/config.yaml): {{GREEN}}$MAC_ADDR{{NORMAL}}"

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

	# An encrypted host comes back into its initrd, not into its system: it now
	# listens on 2222 from the very first boot (the install staged the initrd
	# key), so the passphrase can be answered from here. No-op otherwise.
	just unlock "{{host}}" "$target"

	# NOT "$target": the installer and the installed system do not always land
	# on the same address. Take whichever one actually answers and carry it
	# through the rest of the chain.
	answer=$(just _wait-any "{{host}}" "$target" 22)
	read -r target port <<<"$answer"
	just _log "{{host}} is back at $target." "INSTALL"
	just configure {{host}} "$target"
	just _log "Let's do that automatically..."
	#just _fix_fs_permissions
	just _log "Adding and committing (amend)..." "GIT"

	# Amend only what `just install` itself committed. When it had nothing to
	# commit, HEAD is somebody else's work and amending would rewrite it in
	# silence, so fold the install leftovers into a commit of their own.
	msg="New host {{host}} dnf installation"
	git add .
	if git diff --cached --quiet ;then
		git reset
	elif [ "$(git log -1 --format=%s)" = "$msg" ] ;then
		git commit --amend --no-edit --allow-empty && git reset
	else
		git commit -m "$msg" && git reset
	fi
	just apply-verbose {{host}}
	just _log "Cleaning new system..."
	just gc {{host}}
	just _log "Last reboot..."
	sudo -i -u nix colmena exec --config "{{workDir}}/flake.nix" --on "{{host}}" "nohup bash -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &"

	# Without this an encrypted host ENDS the procedure sitting in its initrd,
	# waiting for a passphrase nobody is there to type — the whole point of a
	# remote install lost on the very last step. No-op on a clear host, and on
	# an encrypted one that came back on 22 on its own.
	just _wait-ssh "$target" down 180 || true
	just unlock "{{host}}" "$target"

	# The redirection was only meant to survive the install: from here the host
	# answers under its own name, at home or wherever it is next plugged in.
	just roaming-clear "{{host}}"
	just _done
	just _log "Don't forget to comment or remove disko config in etc/config.yaml."

# Build DNF iso image. Build from workDir (the consumer flake), whose
# `mkConfigurations` injects the admin pubkey (`usr/secrets/nix.pub`) into the
# ISO — this is what makes it passwordless-installable with `just full-install`.
# A standalone dnf/ checkout has workDir == the framework root, so it falls back
# to the framework's own (keyless) ISO.
#
# Build the DNF ISO image (carries the admin key)
[group('install')]
build-iso arch="x86_64-linux":
	@just _log "Building local DNF ISO image..."
	{{nix}} build {{workDir}}#nixosConfigurations.iso-{{arch}}.config.system.build.isoImage
