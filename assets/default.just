# Darkone framework just file
# darkone@darkone.yt
#
# This Justfile is also imported by the consumer root Justfile. 
# All path-derived variables use `justfile_directory()` so they resolve 
# to the *root* justfile's directory — i.e. the consumer's workspace 
# when imported, or `dnf/` when invoked standalone for framework-only 
# checks (unit-tests, check-flake, ...).

# TODO: Edge case à surveiller : install et install-key appellent en interne just clean qui édite des fichiers du repo. Comme l'appel se fait après le sudo, clean tourne sous nix → si tes fichiers sont owned-dev sans group-write, ça échouera. Si tu vois ce cas, soit retirer just clean de ces recettes (le dev clean avant), soit assouplir les permissions du repo. Je n'ai pas touché à ça pour rester minimaliste.

set shell := ["bash", "-euo", "pipefail", "-c"]

workDir := justfile_directory()
dnfDir := home_directory() + '/dnf'
secretsDir := workDir + '/usr/secrets'
secretsGitIgnore := secretsDir + '/.gitignore'
sopsSecretsFile := secretsDir + '/secrets.yaml'
sopsAdminKeyDir := home_directory() + '/.config/sops/age'
sopsAdminKeyFile := sopsAdminKeyDir + '/keys.txt'
sopsInfraKeyFile := secretsDir + '/infra.key'
sopsYamlFile := secretsDir + '/.sops.yaml'
sopsInfraTargetDir := '/etc/sops/age'
sopsInfraTargetFile := sopsInfraTargetDir + '/infra.key'
generatedConfigFile := workDir + '/var/generated/config.yaml'
nix := 'nix --extra-experimental-features "nix-command flakes"'
logPrefix := '[ {{CYAN}}DNF{{NORMAL}} ] '
dnfInstallDir := '/mnt/dnf-install'

# Repos to iterate in git commands: dnf, doc, all src/* dirs, then .
repos := `printf '%s\n' dnf doc; for d in src/*/; do [ -d "$d/.git" ] && echo "${d%/}"; done; echo .`

alias c := clean
alias d := develop
alias e := enter
alias a := apply
alias al := apply-local
alias av := apply-verbose

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

#==============================================================================
# Check
#==============================================================================

# Recursive deadnix on nix files
[group('check')]
check:
	#!/usr/bin/env bash
	just _log "Full checking..." "DEADNIX"
	find . -name "*.nix" -exec deadnix -eq {} \;

# Check the main flake. Filter benign "unknown flake output" warnings for the
# DNF non-standard outputs (colmena, colmenaHive, homeManagerModules,
# libTests); any *other* unknown output stays visible. sed (vs. grep -v)
# always exits 0, which keeps pipefail honest about nix's real exit status.
[group('check')]
check-flake:
	{{nix}} flake check --all-systems --quiet 2>&1 \
	  | sed -E "/^warning: unknown flake output '(colmena|colmenaHive|homeManagerModules|libTests)'\$/d"

# Check with statix
[group('check')]
check-statix:
	#!/usr/bin/env bash
	just _log "Checking nix configuration..." "STATIX"
	statix check .

# Run unit tests
[group('check')]
unit-tests:
	just _log "Running unit tests..." "TESTS"
	nix-unit --gc-roots-dir /tmp --flake .#libTests

# Run L2 simulation tests (NixOS Test Driver).
# With no argument: runs all scenarios via `nix flake check`.
# With an argument: runs a single named scenario (e.g. `just simulate console-git`).
[group('check')]
simulate what="":
	#!/usr/bin/env bash
	just _log "Running simulation tests..." "SIMULATE"
	if [ -z "{{what}}" ]; then
		{{nix}} flake check --quiet
	else
		system=$({{nix}} eval --raw --impure --expr 'builtins.currentSystem')
		{{nix}} build ".#checks.${system}.{{what}}" --no-link
	fi

#==============================================================================
# Development
#==============================================================================

# format: fix + check + generate + format
[group('dev')]
clean: fix check generate format

# Recursive nixfmt on all nix files
[group('dev')]
format:
	#!/usr/bin/env bash
	just _log "Full formatting..." "NIXFMT"
	find . -name "*.nix" -exec nixfmt -s {} \;

# Fix with statix
[group('dev')]
fix:
	#!/usr/bin/env bash
	just _log "Full fixing..." "STATIX"
	statix fix .

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

#==============================================================================
# Generators
#==============================================================================

# Update the nix generated files
[group('dev')]
generate: \
	(_gen-default "dnf/modules") \
	(_gen-default "usr/modules") \
	(_gen-default "dnf/home/modules") \
	(_gen-default "usr/home/modules") \
	(_gen "users") \
	(_gen "hosts") \
	(_gen "network") \
	(_gen "disko")

# Generator of default.nix files
_gen-default dir:
	#!/usr/bin/env bash
	if [ ! -d "{{dir}}" ] ;then
		just _log "Skipping unknown directory {{dir}}..."
	else
		just _log "{{dir}} ➜ default.nix..." "GENERATOR"
		cd {{dir}}
		echo "# DO NOT EDIT, this is a generated file." > default.nix
		echo >> default.nix
		echo "{ imports = [" >> default.nix
		find . -name "*.nix" | sort | grep -v default.nix >> default.nix
		echo "];}" >> default.nix
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

# Copy pub key to the node (nix user must exist)
[group('install')]
copy-id host:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just copy-id "{{host}}"
	just _log "Copying id to {{host}}..." "SSH"
	ssh-keygen -R {{host}}
	ssh-copy-id -o StrictHostKeyChecking=no -f nix@{{host}}
	just _log "Cleaning authorized_keys..." "SSH"
	ssh nix@{{host}} "sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys"
	ssh -o PasswordAuthentication=no -o PubkeyAuthentication=yes nix@{{host}} 'echo "OK, it works!"'

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
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just enter "{{on}}"
	just _log "Entering {{on}}..." "SSH"
	ssh nix@{{on}}

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

#==============================================================================
# Installation
#==============================================================================

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
		just _log "Maintenance key already exists." "SSH"
	fi
	if [ ! -f "{{secretsDir}}/nix.pub" ] ;then
		if [ ! -f "$HOME/.ssh/id_ed25519.pub" ] ;then
			just _fail "Nix user public key not found!" "SSH"
		else
			cp "$HOME/.ssh/id_ed25519.pub" "{{secretsDir}}/nix.pub"
		fi
	else
		just _log "Public key {{secretsDir}}/nix.pub already exists." "SSH"
	fi
	if [ ! -d ./src/vendor ] ;then
		just _log "Building generator..." "GEN"
		cd ./src && composer install --no-dev && cd ..
	else
		just _log "Generator is ok." "GEN"
	fi
	if [ ! -f {{secretsGitIgnore}} ] ;then
		just _log "Creating usr/secrets directory + gitignore..." "SOPS"
		mkdir -p {{secretsDir}}
		echo '*.key' > {{secretsGitIgnore}}
	else
		just _log "usr/secrets/.gitignore file already exists." "SOPS"
	fi
	if [ ! -f {{sopsAdminKeyFile}} ] ;then
		just _log "Admin key file creation from ssh private key..." "SOPS"
		mkdir -p {{sopsAdminKeyDir}}
		ssh-to-age -private-key -i "$HOME/.ssh/id_ed25519" > {{sopsAdminKeyFile}}
	else
		just _log "Admin key file already exists." "SOPS"
	fi
	if [ ! -f {{sopsInfraKeyFile}} ] ;then
		just _log "Infra private key file generation..." "SOPS"
		age-keygen -o {{sopsInfraKeyFile}}
	else
		just _log "Infra key file already exists." "SOPS"
	fi
	if [ ! -f {{sopsYamlFile}} ] ;then
		just _log "[SOPS] .sops.yaml file generation..."
		INF_PUB_KEY=$(age-keygen -y {{sopsInfraKeyFile}})
		ADM_PUB_KEY=$(age-keygen -y {{sopsAdminKeyFile}})
		[ -f {{sopsYamlFile}} ] || echo "{}" > {{sopsYamlFile}}
		echo "keys:" > {{sopsYamlFile}}
		echo "  - &nix ${ADM_PUB_KEY}" >> {{sopsYamlFile}}
		echo "  - &infra ${INF_PUB_KEY}" >> {{sopsYamlFile}}
		echo "creation_rules:" >> {{sopsYamlFile}}
		echo "  - path_regex: \"[^/]+\\\\.yaml$\"" >> {{sopsYamlFile}}
		echo "    key_groups:" >> {{sopsYamlFile}}
		echo "    - age:" >> {{sopsYamlFile}}
		echo "      - *nix" >> {{sopsYamlFile}}
		echo "      - *infra" >> {{sopsYamlFile}}
	else
		just _log ".sops.yaml file already exists." "SOPS"
	fi
	if [ ! -f {{sopsSecretsFile}} ] ;then
		just _log "We need a default password..." "SOPS"
		just passwd-default
		just push-key localhost
	else
		just _log "Default secret file already exists." "SOPS"
	fi
	just _done

# Extract hardware config from host
[group('install')]
copy-hw host:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just copy-hw "{{host}}"
	just _log "Extracting hardware information..."
	mkdir -p usr/machines/{{host}}
	ssh nix@{{host}} "sudo nixos-generate-config --no-filesystems --show-hardware-config" > usr/machines/{{host}}/hardware-configuration.nix

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
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just install "{{host}}" "{{user}}" "{{ip}}" "{{do}}"
	read -p "Are you sure to format disks and install a new system? (y/N) " ans
	[ "$ans" = "y" ] || { just _log "Aborted." "INSTALL"; exit 1; }
	just _check_infra_admin
	just clean
	just _log "Preparation..."
	if [ ! -f "./usr/machines/{{host}}/default.nix" ]; then
		just _log "[ERR] Host installation script not found." >&2
		just _log "[ERR] Are you sure the host {{host}} exists" >&2
		just _log "[ERR] and have a disko config in etc/config.yaml?" >&2
		exit 1
	fi
	echo "{ }" > ./usr/machines/{{host}}/hardware-configuration.nix
	if [ "{{ip}}" == "auto" ]; then
		TARGET_HOST="{{host}}"
	else
		TARGET_HOST="{{ip}}"
	fi
	just _log "We need to add, commit and build..."
	git add . && (git diff --cached --quiet || git commit -m "New host {{host}} dnf installation") && git reset
	just _log "Launching installation ({{do}})..."
	if [ "{{do}}" == "test" ]; then
		{{nix}} run github:nix-community/nixos-anywhere -- --flake .#{{host}} --vm-test
	elif [ "{{do}}" == "install" ] ;then
		{{nix}} run github:nix-community/nixos-anywhere -- \
			--copy-host-keys \
			--flake .#{{host}} \
			-i "$HOME/.ssh/id_ed25519" \
			--generate-hardware-config nixos-generate-config ./usr/machines/{{host}}/hardware-configuration.nix \
			--target-host {{user}}@$TARGET_HOST
	else
		echo 'ERR: unknown action "{{do}}"'
	fi;
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
		just _log "[ERR] Host configuration not found." >&2
		just _log "[ERR] Are you sure the host {{host}} exists" >&2
		just _log "[ERR] and have a disko config in etc/config.yaml?" >&2
		exit 1
	fi
	sudo mkdir -p {{dnfInstallDir}}
	sudo chown 750 {{dnfInstallDir}}
	just _log "Hardware configuration for usb key..."
	echo "_:{imports=[./../../../dnf/hosts/templates/hardware-usb-key.nix];}" > ./usr/machines/{{host}}/hardware-configuration.nix
	just clean
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
	@just _log "You can register the mac address in etc/config.yaml:"
	ssh nix@{{host}} "ip -o link show up | grep -v 'lo:' | head -n 1 | sed 's/^.* \([0-9a-f:]*\) brd .*$/\1/'"

# Auto-switching here means the chained `copy-id` / `copy-hw` / `push-key`
# already inherit the nix user — their own guards short-circuit cleanly.
#
# New host: ssh cp id, extr. hw, push infra key, clean, info
[group('install')]
configure host:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just configure "{{host}}"
	just _check_infra_admin
	just copy-id "{{host}}"
	just copy-hw "{{host}}"
	just push-key "{{host}}"
	just clean
	just _log "If no error occurs, do not forget to commit and apply:"
	just _log "git add . && git commit -m 'Installing new host {{host}}'"
	just _log "just apply-verbose {{host}}"
	just _host-info "{{host}}"

# New host: full installation (install, configure, apply)
[group('install')]
full-install host user='nix' ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just full-install "{{host}}" "{{user}}" "{{ip}}"
	just install {{host}} {{user}} {{ip}}
	just _log "Waiting for reboot..."
	until ping -c1 -W1 {{host}} >/dev/null 2>&1; do sleep 1; done; echo "Oh, {{host}} is up, waiting 2s and continue... :)"
	sleep 2
	just configure {{host}}
	just _log "Let's do that automatically..."
	just _log "Adding and committing (amend)..." "GIT"
	git add . && (git diff --cached --quiet || git commit --amend --no-edit --allow-empty) && git reset
	just apply-verbose {{host}}
	just _log "Cleaning new system..."
	just gc {{host}}
	just _log "Last reboot..."
	colmena exec --on "{{host}}" "nohup bash -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &"
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
	just _log "Updating default password..." "SOPS"
	if [ -f {{sopsSecretsFile}} ] ;then
		sops -d -i {{sopsSecretsFile}}
	else
		echo "{}" >> {{sopsSecretsFile}}
	fi
	yq -y --arg pw "$PASSWORD" '."default-password" = $pw' {{sopsSecretsFile}} | sponge {{sopsSecretsFile}}
	BCRYPT_HASH=$(mkpasswd --method=bcrypt --rounds=12 "$PASSWORD")
	yq -y --arg pw "$BCRYPT_HASH" '."default-password-hash" = $pw' {{sopsSecretsFile}} | sponge {{sopsSecretsFile}}
	sops -e -i {{sopsSecretsFile}}
	if [ ! -f {{generatedConfigFile}} ] ;then
		echo "{}" >> {{generatedConfigFile}}
	fi
	yq -y --arg pw "$BCRYPT_HASH" '.network.default."password-hash" = $pw' {{generatedConfigFile}} | sponge {{generatedConfigFile}}
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
	just _log "Updating {{user}} password..." "SOPS"
	HASH=$(mkpasswd -m sha-512 "$PASSWORD")
	sops -d -i {{sopsSecretsFile}}
	yq -y --arg pw "$HASH" '.user."{{user}}"."password-hash" = $pw' {{sopsSecretsFile}} | sponge {{sopsSecretsFile}}
	sops -e -i {{sopsSecretsFile}}
	just _log "OK, password updated for {{user}}" "SOPS"
	just _log "Now deploy with 'just apply @user-{{user}}'" "SOPS"

# Build DNF iso image
[group('install')]
build-iso arch="x86_64-linux":
	@just _log "Building local DNF ISO image..."
	{{nix}} build .#nixosConfigurations.iso-{{arch}}.config.system.build.isoImage

#==============================================================================
# Apply (colmena)
#==============================================================================
#
# Admin recipes auto-switch to the `nix` user (which owns the SSH keys and
# SOPS infra key) via `exec sudo -u nix just <recipe>`. The guard short-
# circuits the original shell so the body never runs under the caller's
# user when it isn't nix.
#
# TODO: Binary cache keys + remove --build-on-target -> https://nixos.wiki/wiki/Binary_Cache

# Apply configuration using colmena
[group('apply')]
apply on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Applying nix configuration on {{on}} ({{what}})..."
	sudo -u nix colmena apply --build-on-target --on "{{on}}" {{what}}

# Apply force with verbose options
[group('apply')]
apply-verbose on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just apply-verbose "{{on}}" "{{what}}"
	just _log "Applying (verbose) nix configuration on {{on}} ({{what}})..."
	colmena apply --build-on-target --verbose --show-trace --on "{{on}}" {{what}}

# Apply the local host configuration
[group('apply')]
apply-local what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Applying locally ({{what}})..."
	colmena apply-local --sudo {{what}}

#==============================================================================
# Info / Diagnostic
#==============================================================================

# Show git status and flake info
[group('info')]
status:
	@just _log "Git status..." "INFO"
	@git -C . status --short
	@echo ""
	@just _log "Flake inputs and hosts..." "INFO"
	{{nix}} flake show

#==============================================================================
# Sub-projects
#==============================================================================

# Build the Rust generator
[group('src')]
gen-build:
	just --justfile src/generator/Justfile build

# Run Rust generator unit tests
[group('src')]
gen-test:
	just --justfile src/generator/Justfile test

#==============================================================================
# Dual-repo git helpers (arthur-network + framework)
#==============================================================================

# Add and commit changes in several projects with the same message
[group('dev')]
git-commit msg on="all":
	#!/usr/bin/env bash
	set -euo pipefail

	# Commit all projects
	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			just git-commit "{{msg}}" "$repo"
		done <<< "{{repos}}"
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi
		git -C {{on}} add -A
		if ! git -C {{on}} diff --cached --quiet ;then
			just _log "Committing on {{on}}/" "GIT"
			git -C {{on}} commit -m "{{msg}}" > /dev/null
		else
			just _info "Nothing to commit on {{on}}/" "GIT"
		fi
	fi

# Amend last commit in several projects with current changes (--no-edit)
[group('dev')]
git-amend on="all":
	#!/usr/bin/env bash
	set -euo pipefail

	# Amend all projects
	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			just git-amend "$repo"
		done <<< "{{repos}}"
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi

		# `--allow-empty` keeps the recipe idempotent even when a tree is clean.
		git -C {{on}} add -A
		if ! git -C {{on}} diff --cached --quiet ;then
			just _log "Amending {{on}}/" "GIT"
			git -C {{on}} commit --amend --no-edit --allow-empty > /dev/null
		else
			just _info "Nothing to amend on {{on}}/" "GIT"
		fi
	fi

# Run any git command on all (or a single) project
[group('dev')]
git-status on="all":
	just git "status -s" {{on}} "Status of"


# Show last commit log of all projects with aligned formatting
[group('dev')]
git-last-log:
	#!/usr/bin/env bash
	set -euo pipefail

	repos_list=()
	max_len=0
	while IFS= read -r repo; do
		[ -z "$repo" ] && continue
		repos_list+=("$repo")
		len=${#repo}
		[ "$len" -gt "$max_len" ] && max_len=$len
	done <<< "{{repos}}"

	for repo in "${repos_list[@]}"; do
		msg=$(git -C "$repo" log -1 --pretty='%B' 2>/dev/null | head -n 1)
		[ -z "$msg" ] && continue
		dots=$((max_len - ${#repo} + 2))
		pad=$(printf '%*s' "$dots" '' | tr ' ' '.')
		just _log "Last log of $repo/$pad $msg" "GIT"
	done

# Run any git command on all (or a single) project
[group('dev')]
git cmd on="all" label="":
	#!/usr/bin/env bash
	set -euo pipefail

	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			just git "{{cmd}}" "$repo" "{{label}}"
		done <<< "{{repos}}"
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi
		if [ -n "{{label}}" ]; then
			LABEL="{{label}}"
		else
			LABEL="'git {{cmd}}' on"
		fi
		just _log "$LABEL {{on}}/" "GIT"
		git -C {{on}} {{cmd}}
	fi

# Show repositories
[group('dev')]
git-show-repos:
	@echo "{{repos}}"
