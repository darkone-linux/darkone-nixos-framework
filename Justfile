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

alias c := clean
alias d := develop
alias e := enter
alias a := apply-force
alias al := apply-local
alias av := apply-verbose

# Justfile help
_default:
	@just --list

# Check if we are an infra admin host
_check_infra_admin:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ `whoami` != "nix" ] ;then
		echo "Please execute this command with the 'nix' user."
		exit 1
	fi
	if [ ! -f {{sopsInfraKeyFile}} ] ;then
		echo "Infra private key not found, you must do that from the admin host."
		echo "If you are on the admin host, type 'just install-admin-host' before."
		exit 1
	fi

# Framework installation on local machine (builder / admin)
[group('install')]
configure-admin-host:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ `whoami` != "nix" ]; then
		echo "Only nix user can install and manage DNF configuration."
		exit 1
	fi
	if [ ! -f ~/.ssh/id_ed25519 ] ;then
		echo "-> Creating ssh keys..."
		ssh-keygen -t ed25519 -N ""
	else
		echo "-> Maintenance ssh key already exists."
	fi
	if [ ! -d ./src/vendor ] ;then
		echo "-> Building generator..."
		cd ./src && composer install --no-dev && cd ..
	else
		echo "-> Generator is ok."
	fi
	if [ ! -f {{secretsGitIgnore}} ] ;then
		echo "-> [SOPS] Creating usr/secrets directory + gitignore..."
		mkdir -p {{secretsDir}}
		echo '*.key' > {{secretsGitIgnore}}
	else
		echo "-> [SOPS] usr/secrets/.gitignore file already exists."
	fi
	if [ ! -f {{sopsAdminKeyFile}} ] ;then
		echo "-> [SOPS] Admin key file creation from ssh private key..."
		mkdir -p {{sopsAdminKeyDir}}
		ssh-to-age -private-key -i ~/.ssh/id_ed25519 > {{sopsAdminKeyFile}}
	else
		echo "-> [SOPS] Admin key file already exists."
	fi
	if [ ! -f {{sopsInfraKeyFile}} ] ;then
		echo "-> [SOPS] Infra private key file generation..."
		age-keygen -o {{sopsInfraKeyFile}}
	else
		echo "-> [SOPS] Infra key file already exists."
	fi
	if [ ! -f {{sopsYamlFile}} ] ;then
		echo "-> [SOPS] .sops.yaml file generation..."
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
		echo "-> [SOPS] .sops.yaml file already exists."
	fi
	if [ ! -f {{sopsSecretsFile}} ] ;then
		echo "-> [SOPS] We need a default password..."
		just passwd-default
		just push-key localhost
	else
		echo "-> [SOPS] Default secret file already exists."
	fi
	echo "-> Done"

# format: fix + check + generate + format
[group('dev')]
clean: fix check generate format

# Recursive deadnix on nix files
[group('check')]
check:
	#!/usr/bin/env bash
	echo "-> Checking nix files with deadnix..."
	find . -name "*.nix" -exec deadnix -eq {} \;

# Check the main flake
[group('check')]
check-flake:
	{{nix}} flake check --all-systems

# Check with statix
[group('check')]
check-statix:
	#!/usr/bin/env bash
	echo "-> Checking with statix..."
	statix check .

# Recursive nixfmt on all nix files
[group('dev')]
format:
	#!/usr/bin/env bash
	echo "-> Formatting nix files with nixfmt..."
	find . -name "*.nix" -exec nixfmt -s {} \;

# Fix with statix
[group('dev')]
fix:
	#!/usr/bin/env bash
	echo "-> Fixing source code with statix..."
	statix fix .

# Update the nix generated files
[group('dev')]
generate: \
	(_gen-default "dnf/modules/nix") \
	(_gen-default "usr/modules/nix") \
	(_gen-default "dnf/modules/home") \
	(_gen-default "usr/modules/home") \
	(_gen "users" "var/generated/users.nix") \
	(_gen "hosts" "var/generated/hosts.nix") \
	(_gen "network" "var/generated/network.nix") \
	(_gen-disko "var/generated/disko")

# Generator of default.nix files
_gen-default dir:
	#!/usr/bin/env bash
	if [ ! -d "{{dir}}" ] ;then
		echo "-> Skipping unknown directory {{dir}}..."
	else
		echo "-> generating {{dir}} default.nix..."
		cd {{dir}}
		echo "# DO NOT EDIT, this is a generated file." > default.nix
		echo >> default.nix
		echo "{ imports = [" >> default.nix
		find . -name "*.nix" | sort | grep -v default.nix >> default.nix
		echo "];}" >> default.nix
		nixfmt -s default.nix
	fi

# Generate var/generated/*.nix files
_gen what targetFile:
	#!/usr/bin/env bash
	echo "-> generating {{what}} in {{targetFile}}..."
	echo "# This file is generated by 'just generate'" > "{{targetFile}}"
	echo "# from the configuration file usr/config.yaml" >> "{{targetFile}}"
	echo "# --> DO NOT EDIT <--" >> "{{targetFile}}"
	echo >> "{{targetFile}}"
	php ./src/generate.php "{{what}}" >> "{{targetFile}}"
	nixfmt -s "{{targetFile}}"

# Generate var/generated/disko/*.nix files
_gen-disko targetDir:
	#!/usr/bin/env bash
	echo "-> generating disko files in {{targetDir}}..."
	rm -f {{targetDir}}/*.nix
	mkdir -p {{targetDir}}
	php ./src/generate.php "disko" | awk '{file="{{targetDir}}/" $1 ".nix"; $1=""; sub(/^ /,"# Generated file, do not edit\n\n"); print > file}'

# Launch a "nix develop" with zsh (dev env)
[group('dev')]
develop:
	@echo Lauching nix develop with zsh...
	{{nix}} develop -c zsh

# Copy pub key to the node (nix user must exists)
[group('install')]
copy-id host:
	#!/usr/bin/env bash
	ssh-keygen -R {{host}}
	ssh-copy-id -o StrictHostKeyChecking=no -f nix@{{host}}
	ssh -o PasswordAuthentication=no -o PubkeyAuthentication=yes nix@{{host}} 'echo "OK, it works! You can type \"just install {{host}}\" and apply to {{host}}"'

# Interactive shell to the host
[group('manage')]
enter host:
	ssh nix@{{host}}

# Extract hardware config from host
[group('install')]
copy-hw host:
	#!/usr/bin/env bash
	mkdir -p usr/machines/{{host}}
	ssh nix@{{host}} "sudo nixos-generate-config --show-hardware-config" > usr/machines/{{host}}/hardware-configuration.nix

# Push the infrastructure key to the host
[group('install')]
push-key host:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	ssh nix@{{host}} 'sudo mkdir -p {{sopsInfraTargetDir}}'
	ssh nix@{{host}} 'sudo chown -R nix {{sopsInfraTargetDir}}'
	scp {{sopsInfraKeyFile}} nix@{{host}}:{{sopsInfraTargetFile}}
	ssh nix@{{host}} 'sudo chown -R root {{sopsInfraTargetDir}}'
	ssh nix@{{host}} 'sudo chmod 600 {{sopsInfraTargetFile}}'

# New host: format with nixos-everywhere + disko
[group('install')]
install host user='nix' ip='auto' do='install':
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	echo "-> Preparation..."
	if [ "{{ip}}" == "auto" ]; then
		TARGET_HOST="{{host}}"
	else
		TARGET_HOST="{{ip}}"
	fi
	if [ ! -f ./usr/machines/{{host}}/default.nix ]; then
	  mkdir -p ./usr/machines/{{host}}
		cp ./dnf/hosts/templates/usr-machines-default.nix ./usr/machines/{{host}}/default.nix
	fi
	if [ ! -f ./usr/machines/{{host}}/hardware-configuration.nix ]; then
		echo "{ }" > ./usr/machines/{{host}}/hardware-configuration.nix
	fi
	just clean
	echo "-> We need to add, commit and build..."
	git add . && git commit -m "New host {{host}} dnf installation"
	just apply-local push
	echo "-> Launching installation ({{do}})..."
	if [ "{{do}}" == "test" ]; then
		{{nix}} run github:nix-community/nixos-anywhere -- --flake ./var/generated/disko#{{host}} --vm-test
	elif [ "{{do}}" == "install" ] ;then
		{{nix}} run github:nix-community/nixos-anywhere -- \
			--flake ./var/generated/disko#{{host}} \
			-i ~/.ssh/id_ed25519 \
			--generate-hardware-config nixos-generate-config ./usr/machines/{{host}}/hardware-configuration.nix \
			--target-host {{user}}@$TARGET_HOST
	else
		echo 'ERR: unkown action "{{do}}"'
	fi;
	echo "-> Now you can test nix@{{host}} and run 'just configure {{host}}'"

# Get a mac address
_info host:
	echo "-> You can register the mac address in usr/config.yaml:"
	ssh nix@{{host}} "ip -o link show up | grep -v 'lo:' | head -n 1 | sed 's/^.* \([0-9a-f:]*\) brd .*$/\1/'"

# New host: ssh cp id, extr. hw, clean, commit, apply
[group('install')]
configure host:
	@just _check_infra_admin
	@echo "-> Copying ssh identity..."
	@just copy-id {{host}}
	@echo "-> Extracting hardware information..."
	@just copy-hw {{host}}
	@echo "-> Pushing infra key file..."
	@just push-key {{host}}
	@echo "-> Clean and commiting before apply..."
	@just clean
	@echo "-> If not error occurs, do not forget to commit and apply:"
	@echo "git add . && git commit -m 'Installing new host {{host}}'"
	@echo "just apply-verbose {{host}}"
	@just _info {{host}}

# New host: full installation (install, configure, apply)
[group('install')]
full-install host user='nix' ip='auto' do='install':
	#!/usr/bin/env bash
	set -euo pipefail
	just install {{host}} {{user}} {{ip}} {{do}}
	echo "-> Waiting for reboot..."
	until ping -c1 -W1 {{host}} >/dev/null 2>&1; do sleep 1; done; echo "Oh, {{host}} is up, waiting 2s and continue... :)"
	sleep 2
	just configure {{host}}
	echo "-> We need to add and commit (amend)..."
	git add . && git commit --amend --no-edit
	just apply-verbose {{host}}
	echo "-> Last reboot..."
	colmena exec --on "{{host}}" "sudo systemctl reboot"
	echo "-> Done"

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
		echo "Error: not corresponding."
		exit 1
	fi
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
	echo "Password updated, dont forget to deploy"

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
		echo "Error: not corresponding."
		exit 1
	fi
	HASH=$(mkpasswd -m sha-512 "$PASSWORD")
	sops -d -i {{sopsSecretsFile}}
	yq -y --arg pw "$HASH" '.user.{{user}}."password-hash" = $pw' {{sopsSecretsFile}} | sponge {{sopsSecretsFile}}
	sops -e -i {{sopsSecretsFile}}
	echo "Password updated for {{user}}"
	echo "Now deploy with 'just apply @user-{{user}}'"

# Apply configuration using colmena
[group('apply')]
apply on what='switch':
	colmena apply --eval-node-limit 3 --evaluator streaming --on "{{on}}" {{what}}

# Apply with build-on-target + force repl. unk profiles
[group('apply')]
apply-force on what='switch':
	colmena apply --eval-node-limit 3 --evaluator streaming --build-on-target --force-replace-unknown-profiles --on "{{on}}" {{what}}

# Apply force with verbose options
[group('apply')]
apply-verbose on what='switch':
	colmena apply --eval-node-limit 3 --evaluator streaming --build-on-target --force-replace-unknown-profiles --verbose --show-trace --on "{{on}}" {{what}}

# Multi-reboot (using colmena)
[group('manage')]
[confirm]
reboot on:
	colmena exec --on "{{on}}" "sudo systemctl reboot"

# Multi-alt (using colmena)
[group('manage')]
[confirm]
halt on:
	colmena exec --on "{{on}}" "sudo systemctl poweroff"

# Remove zshrc bkp to avoid error when replacing zshrc
[group('manage')]
fix-zsh on:
	colmena exec --on "{{on}}" "rm -f .zshrc.bkp"

# Multi garbage collector (using colmena)
[group('manage')]
gc on:
	colmena exec --on "{{on}}" "sudo nix-collect-garbage -d && sudo /run/current-system/bin/switch-to-configuration boot"

# Multi-reinstall bootloader (using colmena)
[group('manage')]
fix-boot on:
	colmena exec --on "{{on}}" "sudo NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"

# Apply the local host configuration
[group('apply')]
apply-local what='switch':
	colmena apply-local --sudo {{what}}

# Pull common files from DNF repository
[group('dev')]
pull:
	#!/usr/bin/env bash
	if [[ `git status -s` != '' ]] ;then
		echo "ERR: please commit your changes before."
		exit 1
	fi
	if [ ! -d "{{dnfDir}}" ] ;then
		echo "ERR: {{dnfDir}} do not exists."
		exit 1
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
	if [ ! -d "{{dnfDir}}" ] ;then
		echo "ERR: {{dnfDir}} do not exists."
		exit 1
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

# Nix shell with tools to create usb keys
[group('install')]
format-dnf-shell:
	nix-shell -p parted btrfs-progs nixos-install

# Build iso image
[group('install')]
build-iso:
	{{nix}} build .#nixosConfigurations.iso.config.system.build.isoImage

# Format and install DNF on an usb key (danger)
[confirm('This command is dangerous. Are you sure? (y/N)')]
[group('install')]
format-dnf-on host dev:
	#!/usr/bin/env bash
	echo "-> checking..."
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
	echo "-> Preparing..."
	umount -R /mnt
	echo "-> Start installation of {{host}} in {{dev}}..."
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
