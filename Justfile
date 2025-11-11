# Darkone framework just file
# darkone@darkone.yt

set shell := ["bash", "-euo", "pipefail", "-c"]

workDir := source_directory()
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

alias c := clean
alias d := develop
alias e := enter
alias a := apply-force
alias al := apply-local
alias av := apply-verbose

# Justfile help
_default:
	@just --list

# Log
_log msg context="":
	#!/usr/bin/env bash
	if [ "{{context}}" == "" ] ;then
		echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{msg}}"
	else
		echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{BOLD + MAGENTA}}{{context}}{{NORMAL}} • {{msg}}"
	fi

# Error
_err msg:
	@echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{BOLD + RED}}ERR{{NORMAL}} {{msg}}" >&2

# Warn
_warn msg:
	@echo "[ {{BOLD + CYAN}}DNF{{NORMAL}} ] {{BOLD + YELLOW}}WRN{{NORMAL}} {{msg}}" >&2

# Done
_done:
	@just _log "{{GREEN}}Done{{NORMAL}}"

# Fail
_fail msg:
	@just _err "{{msg}}"
	@exit 1

# Check if we are an infra admin host
_check_infra_admin:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ "${USER:-}" != "nix" ] ;then
		just _fail "Please execute this command with the 'nix' user."
	fi
	if [ ! -f {{sopsInfraKeyFile}} ] ;then
		just _err "Infra private key not found, you must do that from the admin host."
		just _fail "If you are on the admin host, type 'just install-admin-host' before."
	fi

# Framework installation on local machine (builder / admin)
[group('install')]
configure-admin-host:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ "${USER:-}" != "nix" ]; then
		just _fail "Only nix user can install and manage DNF configuration."
	fi
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

# format: fix + check + generate + format
[group('dev')]
clean: fix check generate format

# Recursive deadnix on nix files
[group('check')]
check:
	#!/usr/bin/env bash
	just _log "Full checking..." "DEADNIX"
	find . -name "*.nix" -exec deadnix -eq {} \;

# Check the main flake
[group('check')]
check-flake:
	{{nix}} flake check --all-systems

# Check with statix
[group('check')]
check-statix:
	#!/usr/bin/env bash
	just _log "Checking nix configuration..." "STATIX"
	statix check .

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
_gen what:
	#!/usr/bin/env bash
	just _log "{{what}} file(s)..." "GENERATOR"
	php ./src/generate.php "{{what}}"

# Launch a "nix develop" with zsh (dev env)
[group('dev')]
develop:
	@just _log "Lauching nix develop with zsh..."
	{{nix}} develop -c zsh

# Copy pub key to the node (nix user must exists)
[group('install')]
copy-id host:
	#!/usr/bin/env bash
	just _log "Copying id to {{host}}..." "SSH"
	ssh-keygen -R {{host}}
	ssh-copy-id -o StrictHostKeyChecking=no -f nix@{{host}}
	just _log "Cleaning authorized_keys..." "SSH"
	ssh nix@{{host}} "sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys"
	ssh -o PasswordAuthentication=no -o PubkeyAuthentication=yes nix@{{host}} 'echo "OK, it works! You can type \"just install {{host}}\" and apply to {{host}}"'

# Interactive shell to the host
[group('manage')]
enter host:
	@just _log "Entering {{host}}..." "SSH"
	ssh nix@{{host}}

# Extract hardware config from host
[group('install')]
copy-hw host:
	#!/usr/bin/env bash
	just _log "Extracting hardware information..."
	mkdir -p usr/machines/{{host}}
	ssh nix@{{host}} "sudo nixos-generate-config --no-filesystems --show-hardware-config" > usr/machines/{{host}}/hardware-configuration.nix

# Push the infrastructure key to the host
[group('install')]
push-key host:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	just _log "Pushing infra key file..." "SOPS"
	ssh nix@{{host}} 'sudo mkdir -p {{sopsInfraTargetDir}}'
	ssh nix@{{host}} 'sudo chown -R nix {{sopsInfraTargetDir}}'
	scp {{sopsInfraKeyFile}} nix@{{host}}:{{sopsInfraTargetFile}}
	ssh nix@{{host}} 'sudo chown -R root {{sopsInfraTargetDir}}'
	ssh nix@{{host}} 'sudo chmod 600 {{sopsInfraTargetFile}}'

# New host: format with nixos-everywhere + disko
[group('install')]
[confirm('Are you sure to format disks and install a new system? (y/N)')]
install host user='nix' ip='auto' do='install':
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	just clean
	just _log "Preparation..."
	if [ ! -f "./var/generated/disko/install-{{host}}.nix" ]; then
		just _log "[ERR] Host installation script not found." >&2
		just _log "[ERR] Are you sure the host {{host}} exists" >&2
		just _log "[ERR] and have a disko config in usr/config.yaml?" >&2
		exit 1
	fi
	#DISKO_TPL=$(cat var/generated/disko/install-{{host}}.nix | grep DISKO_PROFILE | cut -d' ' -f3)
	#if [ ! -f $DISKO_TPL ] ;then
	#	just _log "[ERR] Host disko template '$DISKO_TPL' not found." >&2
	#	exit 1
	#fi
	#mkdir -p ./usr/machines/{{host}}
	#cp $DISKO_TPL ./usr/machines/{{host}}/disko.nix
	echo "{ }" > ./usr/machines/{{host}}/hardware-configuration.nix
	#if [ ! -f ./usr/machines/{{host}}/default.nix ]; then
	#	cp ./dnf/hosts/templates/usr-machines-default.nix ./usr/machines/{{host}}/default.nix
	#fi
	if [ "{{ip}}" == "auto" ]; then
		TARGET_HOST="{{host}}"
	else
		TARGET_HOST="{{ip}}"
	fi
	just _log "We need to add, commit and build..."
	git add . && (git diff --cached --quiet || git commit -m "New host {{host}} dnf installation") && git reset
	just apply-local push
	just _log "Launching installation ({{do}})..."
	if [ "{{do}}" == "test" ]; then
		{{nix}} run github:nix-community/nixos-anywhere -- --flake ./var/generated/disko#{{host}} --vm-test
	elif [ "{{do}}" == "install" ] ;then
		{{nix}} run github:nix-community/nixos-anywhere -- \
			--flake ./var/generated/disko#{{host}} \
			-i "$HOME/.ssh/id_ed25519" \
			--generate-hardware-config nixos-generate-config ./usr/machines/{{host}}/hardware-configuration.nix \
			--target-host {{user}}@$TARGET_HOST
	else
		echo 'ERR: unkown action "{{do}}"'
	fi;
	just _log "Now you can test nix@{{host}} and run 'just configure {{host}}'"

# Get a mac address
_info host:
	@just _log "You can register the mac address in usr/config.yaml:"
	ssh nix@{{host}} "ip -o link show up | grep -v 'lo:' | head -n 1 | sed 's/^.* \([0-9a-f:]*\) brd .*$/\1/'"

# New host: ssh cp id, extr. hw, clean, commit, apply
[group('install')]
configure host:
	@just _check_infra_admin
	@just copy-id {{host}}
	@just copy-hw {{host}}
	@just push-key {{host}}
	@just clean
	@just _log "If not error occurs, do not forget to commit and apply:"
	@just _log "git add . && git commit -m 'Installing new host {{host}}'"
	@just _log "just apply-verbose {{host}}"
	@just _info {{host}}

# New host: full installation (install, configure, apply)
[group('install')]
full-install host user='nix' ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	just install {{host}} {{user}} {{ip}}
	just _log "Waiting for reboot..."
	until ping -c1 -W1 {{host}} >/dev/null 2>&1; do sleep 1; done; echo "Oh, {{host}} is up, waiting 2s and continue... :)"
	sleep 2
	just configure {{host}}
	just _log "Let's do that automatically..."
	just _log "Adding and committing (amend)..." "GIT"
	git add . && (git diff --cached --quiet || git commit --amend --no-edit) && git reset
	just apply-verbose {{host}}
	just _log "Last reboot..."
	colmena exec --on "{{host}}" "nohup bash -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &"
	just _done
	just _log "Don't forget to comment or remove disko config in usr/config.yaml."

# Update the default DNF password
[group('install')]
passwd-default:
	#!/usr/bin/env bash
	set -euo pipefail
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
	just _log "Password updated, dont forget to deploy" "SOPS"

# Update a user password
[group('install')]
passwd user:
	#!/usr/bin/env bash
	set -euo pipefail
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

# Apply configuration using colmena
[group('apply')]
apply on what='switch':
	@just _log "Applying nix configuration on {{on}} ({{what}})..."
	colmena apply --eval-node-limit 3 --evaluator streaming --on "{{on}}" {{what}}

# Apply with build-on-target + force repl. unk profiles
[group('apply')]
apply-force on what='switch':
	@just _log "Applying (force) nix configuration on {{on}} ({{what}})..."
	colmena apply --eval-node-limit 3 --evaluator streaming --build-on-target --force-replace-unknown-profiles --on "{{on}}" {{what}}

# Apply force with verbose options
[group('apply')]
apply-verbose on what='switch':
	@just _log "Applying (verbose) nix configuration on {{on}} ({{what}})..."
	colmena apply --eval-node-limit 3 --evaluator streaming --build-on-target --force-replace-unknown-profiles --verbose --show-trace --on "{{on}}" {{what}}

# Multi-reboot (using colmena)
[group('manage')]
[confirm]
reboot on:
	@just _log "Rebooting {{on}}..."
	colmena exec --on "{{on}}" "nohup bash -c 'sleep 1; sudo systemctl reboot' >/dev/null 2>&1 &"

# Multi-alt (using colmena)
[group('manage')]
[confirm]
halt on:
	@just _log "Halting {{on}}..."
	colmena exec --on "{{on}}" "nohup bash -c 'sleep 1; sudo systemctl poweroff' >/dev/null 2>&1 &"

# Remove zshrc bkp to avoid error when replacing zshrc
[group('manage')]
fix-zsh on:
	@just _log "Fixing ZSH on {{on}}..."
	colmena exec --on "{{on}}" "rm -f .zshrc.bkp"

# Multi garbage collector (using colmena)
[group('manage')]
gc on:
	@just _log "Garbage collecting on {{on}}..."
	colmena exec --on "{{on}}" "sudo nix-collect-garbage -d && sudo /run/current-system/bin/switch-to-configuration boot"

# Multi-reinstall bootloader (using colmena)
[group('manage')]
fix-boot on:
	@just _log "Fixing boot of {{on}}..."
	colmena exec --on "{{on}}" "sudo NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"

# Apply the local host configuration
[group('apply')]
apply-local what='switch':
	@just _log "Applying locally ({{what}})..."
	colmena apply-local --sudo {{what}}

# Pull common files from DNF repository
[group('dev')]
pull:
	#!/usr/bin/env bash
	just _log "Pulling changes from DNF main project..."
	if [[ `git status -s` != '' ]] ;then
		just _fail "Please commit your changes before."
	fi
	if [ ! -d "{{dnfDir}}" ] ;then
		just _fail "{{dnfDir}} do not exists."
	fi
	cd {{dnfDir}} && \
		git pull --rebase --force && \
		rsync -av --delete \
			--exclude 'usr' \
			--exclude 'var' \
			--exclude '.*' \
			--exclude '*.lock' \
			--exclude node_modules \
			--exclude doc/dist \
			--exclude doc/darkone-linux.github.io \
			{{dnfDir}}/ {{workDir}}/

# Push common files to DNF repository
[group('dev')]
push:
	#!/usr/bin/env bash
	just _log "Pushing changes to DNF main project..."
	if [ ! -d "{{dnfDir}}" ] ;then
		just _fail "{{dnfDir}} do not exists."
	fi
	rsync -av --delete \
		--exclude 'usr' \
		--exclude 'var' \
		--exclude '.*' \
		--exclude '*.lock' \
		--exclude doc/node_modules \
		--exclude doc/dist \
		--exclude doc/darkone-linux.github.io \
		--delete {{workDir}}/ {{dnfDir}}/

# just clean + git amend + apply-local test
[group('dev')]
cat:
	#!/usr/bin/env bash
	set -euo pipefail
	just clean
	git add . && git commit --amend --no-edit
	just apply-local test

# Build DNF iso image
[group('install')]
build-iso arch="x86_64-linux":
	@just _log "Building local DNF ISO image..."
	{{nix}} build .#nixosConfigurations.iso-{{arch}}.config.system.build.isoImage

# Nix shell with tools to create usb keys (deprecated)
[group('install')]
format-dnf-shell:
	nix-shell -p parted btrfs-progs nixos-install

# Format and install DNF on an usb key (deprecated)
[confirm('This command is dangerous. Are you sure? (y/N)')]
[group('install')]
format-dnf-on host dev:
	#!/usr/bin/env bash
	just _log "checking..."
	if [ `whoami` != 'root' ] ;then
	echo "Only root can perform this operation."
		exit 1
	fi
	if ! command -v parted 2>&1 >/dev/null ;then
		echo "parted is required"
		exit 1
	fi
	if ! command -v btrfs 2>&1 >/dev/null ;then
		echo "btrfs is required"
		exit 1
	fi
	if ! command -v mkfs.fat 2>&1 >/dev/null ;then
		echo "mkfs.fat is required"
		exit 1
	fi
	if ! command -v mkfs.btrfs 2>&1 >/dev/null ;then
		echo "mkfs.btrfs is required"
		exit 1
	fi
	if ! command -v nixos-install 2>&1 >/dev/null ;then
		echo "nixos-install is required"
		exit 1
	fi
	if ! command -v nixos-generate-config 2>&1 >/dev/null ;then
		echo "nixos-generate-config is required"
		exit 1
	fi
	just _log "Preparing..."
	umount -R /mnt
	just _log "Start installation of {{host}} in {{dev}}..."
	DISK={{dev}}
	OPTS=defaults,x-mount.mkdir,noatime,nodiratime,ssd,compress=zstd:3
	parted $DISK -- mklabel gpt && \
	parted $DISK -- mkpart ESP fat32 1MB 500MB && \
	parted $DISK -- mkpart root btrfs 500MB 100% && \
	parted $DISK -- set 1 esp on && \
	mkfs.fat -F 32 -n BOOT ${DISK}'1' && \
	mkfs.btrfs -f -L NIXOS ${DISK}'2' && \
	mount ${DISK}'2' /mnt && \
	btrfs subvolume create /mnt/@ && \
	btrfs subvolume create /mnt/@home && \
	umount /mnt && \
	mount -o $OPTS,subvol=@ ${DISK}'2' /mnt && \
	mount -o $OPTS,subvol=@home ${DISK}'2' /mnt/home && \
	mount --mkdir -o umask=077 ${DISK}'1' /mnt/boot && \
	nixos-generate-config --root /mnt && \
	echo '''{ config, lib, pkgs, ... }:
	{
	imports =
		[ # Include the results of the hardware scan.
		./hardware-configuration.nix
		];
	boot.loader.systemd-boot.enable = true;
	boot.loader.efi.canTouchEfiVariables = true;
	networking.hostName = "{{host}}";
	time.timeZone = "America/Miquelon";
	i18n.defaultLocale = "fr_FR.UTF-8";
	console = {
		font = "Lat2-Terminus16";
		keyMap = lib.mkForce "fr";
		useXkbConfig = true;
	};
	users.users.nix = {
		uid = 65000;
		initialPassword = "nixos";
		isNormalUser = true;
		extraGroups = [ "wheel" ];
	};
	security.sudo.wheelNeedsPassword = false;
	environment.systemPackages = with pkgs; [
		vim
	];
	services.openssh.enable = true;
	system.stateVersion = "25.05";
	}
	''' > /mnt/etc/nixos/configuration.nix && \
	nixos-install --root /mnt --no-root-passwd
