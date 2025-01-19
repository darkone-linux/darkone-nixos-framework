# Darkone framework just file
# darkone@darkone.yt

#alias c := clean
#alias f := fix
#alias g := generate

generatedHostFile := './var/generated/hosts.nix'
nixKeyDir := './var/security/ssh'
nixKeyFile := nixKeyDir + '/id_ed25519_nix'

# Justfile help
_default:
	@just --list

# Framework installation (wip)
[group('_main')]
install:
	#!/usr/bin/env bash
	if [ ! -d {{nixKeyDir}} ] ;then
		echo "-> Creating {{nixKeyDir}} directory..."
		mkdir -p {{nixKeyDir}}
	fi
	if [ ! -f {{nixKeyFile}} ] ;then
	  echo "-> Creating ssh keys..."
		ssh-keygen -t ed25519 -f {{nixKeyFile}} -N ""
	else
		echo "-> Maintenance ssh key already exists."
	fi
	if [ ! -d ./src/vendor ] ;then
		echo "-> Building generator..."
		cd ./src && composer install --no-dev && cd ..
	else
		echo "-> Generator is ok."
	fi
	ssh-add {{nixKeyFile}}
	echo "-> Done"

# format (nixfmt) + generate + check (deadnix)
[group('_main')]
clean: fix format generate check

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
	statix check .

# Recursive nixfmt on all nix files
[group('touch')]
format:
	#!/usr/bin/env bash
	echo "-> Formatting nix files with nixfmt..."
	find . -name "*.nix" -exec nixfmt -s {} \;

# Fix with statix
[group('touch')]
fix:
	#!/usr/bin/env bash
	echo "-> Fixing source code with statix..."
	statix fix .

# Update the nix generated files
[group('touch')]
generate: _gen-default-lib-modules _gen-default-usr-modules _gen-default-overlays _gen-hosts

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


# Generate var/generated/hosts.nix
# TODO: generate with nix generator
_gen-hosts:
	#!/usr/bin/env bash
	echo "-> generating hosts..."
	echo "# This file is generated by 'just generate'" > "{{generatedHostFile}}"
	echo "# from the configuration file usr/config.yaml" >> "{{generatedHostFile}}"
	echo "# --> DO NOT EDIT <--" >> "{{generatedHostFile}}"
	echo >> "{{generatedHostFile}}"
	php ./src/generator.php >> "{{generatedHostFile}}"
	nixfmt -s "{{generatedHostFile}}"

# Copy local id on a new node (wip)
[group('utils')]
ssh-copy-id host:
	#!/usr/bin/env bash
	ssh-copy-id -i "{{nixKeyFile}}.pub" -t /home/nix/.ssh/authorized_keys {{host}}
	ssh {{host}} 'chown -R nix:users /home/nix/.ssh'

