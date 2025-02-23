# Darkone framework just file
# darkone@darkone.yt

workDir := '/etc/nixos'
dnfDir := '/home/nix/dnf'

# NOT WORKING FOR THE MOMENT
# TODO: use this key with colmena
nixKeyDir := './var/security/ssh'
nixKeyFile := nixKeyDir + '/id_ed25519_nix'

# Cannot use {{workDir}}...
set working-directory := "/etc/nixos"

#alias c := clean
#alias f := fix
#alias g := generate

# Justfile help
_default:
	@just --list

# Framework installation on local machine (builder)
[group('install')]
install-local:
	#!/usr/bin/env bash
	if [ `whoami` != "nix" ]; then
		echo "Only nix user can install and manage DNF configuration."
		exit 1
	fi
	#if [ ! -d {{nixKeyDir}} ] ;then
	#	echo "-> Creating {{nixKeyDir}} directory..."
	#	mkdir -p {{nixKeyDir}}
	#fi
	#if [ ! -f {{nixKeyFile}} ] ;then
	#  echo "-> Creating ssh keys..."
	#	ssh-keygen -t ed25519 -f {{nixKeyFile}} -N ""
	#else
	#	echo "-> Maintenance ssh key already exists."
	#fi
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
	#ssh-add {{nixKeyFile}}
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
	nix flake check

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
	(_gen-default "dnf/overlays") \
	(_gen-default "usr/overlays") \
	(_gen "users" "var/generated/users.nix") \
	(_gen "hosts" "var/generated/hosts.nix") \
	(_gen "networks" "var/generated/networks.nix")

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

# Copy pub key to the node (nix user must exists)
[group('install')]
copy-id host:
	#!/usr/bin/env bash
	ssh-copy-id -f nix@{{host}}
	ssh -o PasswordAuthentication=no -o PubkeyAuthentication=yes nix@{{host}} 'echo "OK, it works! You can apply to {{host}}"'
	#ssh-copy-id -i "{{nixKeyFile}}.pub" -t /home/nix/.ssh/authorized_keys nix@{{host}}
	#ssh -o PasswordAuthentication=no -o PubkeyAuthentication=yes -i {{nixKeyFile}} nix@{{host}} 'echo "OK, it works! You can apply to {{host}}"'

# Interactive shell to the host
[group('manage')]
enter host:
	ssh nix@{{host}}
	#ssh -i {{nixKeyFile}} nix@{{host}}

# Extract hardware config from host
[group('install')]
copy-hw host:
	#!/usr/bin/env bash
	ssh nix@{{host}} 'test -f /etc/nixos/hardware-configuration.nix'
	if [ $? -eq 0 ]; then
		echo "-> A hardware configuration exists, extracting..."
		mkdir -p usr/machines/{{host}}
		scp nix@{{host}}:/etc/nixos/hardware-configuration.nix usr/machines/{{host}}/default.nix
	else
		echo "-> ERR: no hardware configuration found on {{host}}"
	fi

# New host: ssh cp id, extr. hw, clean, commit, apply
[group('install')]
install host:
	@echo "-> Copying ssh identity..."
	@just copy-id {{host}}
	@echo "-> Extracting hardware information..."
	@just copy-hw {{host}}
	@echo "-> Clean and commiting before apply..."
	@just clean
	git add . && git commit -m "Installing new host {{host}}"
	@echo "-> First apply {{host}}..."
	@just apply-force {{host}}

# Apply configuration using colmena
[group('apply')]
apply on what='switch':
	colmena apply --eval-node-limit 3 --evaluator streaming --on "{{on}}" {{what}}

# Apply with build-on-target + force repl. unk profiles
[group('apply')]
apply-force on what='switch':
	colmena apply --eval-node-limit 3 --evaluator streaming --build-on-target --force-replace-unknown-profiles --on "{{on}}" {{what}}

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
		rsync -av --exclude 'usr' --exclude 'var' --exclude '.*' --exclude '*.lock' {{dnfDir}}/ {{workDir}}/

# Push common files to DNF repository
[group('dev')]
push:
	#!/usr/bin/env bash
	if [ ! -d "{{dnfDir}}" ] ;then
		echo "ERR: {{dnfDir}} do not exists."
		exit 1
	fi
	rsync -av --exclude 'usr' --exclude 'var' --exclude '.*' --exclude '*.lock' {{workDir}}/ {{dnfDir}}/

# Nix shell with tools to create usb keys
[group('install')]
format-dnf-shell:
	nix-shell -p parted btrfs-progs nixos-install

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
