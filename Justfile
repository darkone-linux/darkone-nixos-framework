# Darkone framework just file
# darkone@darkone.yt

#alias c := clean
#alias f := fix
#alias g := generate

# NOT WORKING FOR THE MOMENT
# TODO: use this key with colmena
nixKeyDir := './var/security/ssh'
nixKeyFile := nixKeyDir + '/id_ed25519_nix'

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
	@echo "-> Checking nix files with deadnix..."
	find . -name "*.nix" -exec deadnix -eq {} \;

# Check the main flake
[group('check')]
check-flake:
	nix flake check

# Check with statix
[group('check')]
check-statix:
	statix check .

# Recursive nixfmt on all nix files
[group('dev')]
format:
	@echo "-> Formatting nix files with nixfmt..."
	find . -name "*.nix" -exec nixfmt -s {} \;

# Fix with statix
[group('dev')]
fix:
	@echo "-> Fixing source code with statix..."
	statix fix .

# Update the nix generated files
[group('dev')]
generate: _gen-default-lib-modules _gen-default-usr-modules _gen-default-overlays \
		(_gen "users" "var/generated/users.nix") \
		(_gen "hosts" "var/generated/hosts.nix") \
		(_gen "networks" "var/generated/networks.nix")

# Generate default.nix of lib/modules dir
_gen-default-lib-modules: (_gen-default "lib/modules")

# Generate default.nix of usr/modules dir
_gen-default-usr-modules: (_gen-default "usr/modules")

# Generate default.nix of lib/overlays
_gen-default-overlays: (_gen-default "lib/overlays")

# Generator of default.nix files
_gen-default dir:
	#!/usr/bin/env bash
	echo "-> generating {{dir}} default.nix..."
	cd {{dir}}
	echo "# DO NOT EDIT, this is a generated file." > default.nix
	echo >> default.nix 
	echo "{ imports = [" >> default.nix
	find . -name "*.nix" | sort | grep -v default.nix >> default.nix
	echo "];}" >> default.nix
	nixfmt -s default.nix

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
		echo "-> Une configuration hardware existe, copie..."
		mkdir -p usr/machines/{{host}}
		scp nix@{{host}}:/etc/nixos/hardware-configuration.nix usr/machines/{{host}}/default.nix
	else
		echo "-> ERR: pas de configuration hardware sur {{host}}"
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
	@just apply {{host}}

# Apply configuration using colmena
[group('dev')]
apply on what='switch':
	colmena apply --eval-node-limit 3 --evaluator streaming --on "{{on}}" {{what}}

# Reboot (using colmena)
[group('manage')]
reboot on:
	colmena exec --on "{{on}}" "sudo systemctl reboot"

# Halt (using colmena)
[group('manage')]
halt on:
	colmena exec --on "{{on}}" "sudo systemctl poweroff"

# Garbage collector (using colmena)
[group('manage')]
gc on:
	colmena exec --on "{{on}}" "sudo nix-collect-garbage -d && sudo /run/current-system/bin/switch-to-configuration boot"

# Apply the local host configuration
[group('dev')]
apply-local what='switch':
	colmena apply-local --sudo {{what}}

