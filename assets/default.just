# Darkone framework just file
# darkone@darkone.yt
#
# This Justfile is also imported by the consumer root Justfile. 
# All path-derived variables use `justfile_directory()` so they resolve 
# to the *root* justfile's directory — i.e. the consumer's workspace 
# when imported, or `dnf/` when invoked standalone for framework-only 
# checks (unit-tests, check-flake, ...).

# TODO: Edge case à surveiller : install et install-key appellent en interne just clean qui édite des fichiers du repo. Comme l'appel se fait après le sudo, clean tourne sous nix → si tes fichiers sont owned-dev sans group-write, ça échouera. Si tu vois ce cas, soit retirer just clean de ces recettes (le dev clean avant), soit assouplir les permissions du repo. Je n'ai pas touché à ça pour rester minimaliste.

# `set shell` applies per-line to non-shebang recipes (each line is a separate
# `bash -euo pipefail -c "..."` invocation). Shebang recipes (`#!/usr/bin/env bash`)
# bypass this entirely and run as plain scripts — they need their own `set -euo pipefail`.
set shell := ["bash", "-euo", "pipefail", "-c"]

workDir := justfile_directory()
dnfDir := source_directory() + '/..'
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
fixturesDir := dnfDir + '/tests/fixtures'
nix := 'nix --extra-experimental-features "nix-command flakes"'
logPrefix := '[ {{CYAN}}DNF{{NORMAL}} ] '
dnfInstallDir := '/mnt/dnf-install'

# Repos to iterate in git commands: dnf, doc, all src/* dirs, then .
repos := `for d in src/*/; do [ -d "$d/.git" ] && echo "${d%/}"; done; printf '%s\n' dnf doc .`

alias a := apply
alias c := clean
alias d := develop
alias e := enter
alias g := git
alias al := apply-local
alias av := apply-verbose
alias amend := git-amend
alias commit := git-commit
alias diff := git-diff
alias status := git-status
alias push := git-push
alias pull := git-pull

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

_fix_fs_permissions:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Fixing filesystem permissions..." "FS"
	sudo chown -R --reference=. .
	sudo chmod 644 {{sopsSecretsFile}}
	if [ -d {{secretsDir}} ] ;then
		sudo chown nix {{secretsDir}}/*.key
		sudo chmod 600 {{secretsDir}}/*.key
	fi

_sops_before_edit:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Switch permissions for secrets..." "SOPS"
	if [ -d {{secretsDir}} ] ;then
		sudo chown -R nix {{secretsDir}}
	fi
	if [ -f {{sopsSecretsFile}} ] ;then
		sudo chmod 600 {{sopsSecretsFile}}
	fi

#==============================================================================
# Check
#==============================================================================

# Recursive deadnix on nix files
[group('check')]
check:
	#!/usr/bin/env bash
	set -euo pipefail
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
	set -euo pipefail
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
	set -euo pipefail
	just _log "Running simulation tests..." "SIMULATE"
	if [ -z "{{what}}" ]; then
		{{nix}} flake check --quiet
	else
		system=$({{nix}} eval --raw --impure --expr 'builtins.currentSystem')
		{{nix}} build ".#checks.${system}.{{what}}" --no-link
	fi

# Interactive driver for one scenario (Python REPL inside the test driver).
# Useful to step through a failing scenario: `start_all()`, then drive nodes
# (`node1.succeed(...)`, `node1.shell_interact()`, ...). Pipe a heredoc on
# stdin for non-interactive smoke-runs.
[group('check')]
simulate-debug what:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Interactive driver for {{what}}..." "SIMULATE"
	system=$({{nix}} eval --raw --impure --expr 'builtins.currentSystem')
	{{nix}} run ".#checks.${system}.{{what}}.driverInteractive"

# Manage test fixtures: generate | check | gen-secrets
[group('check')]
fixtures action:
	#!/usr/bin/env bash
	set -euo pipefail
	case "{{action}}" in
	  generate)    just _fixtures_generate ;;
	  check)       just _fixtures_check ;;
	  gen-secrets) just _fixtures_gen_secrets ;;
	  *)           just _fail "Unknown fixtures action: {{action}} (generate|check|gen-secrets)" ;;
	esac

# Generate hosts/users/network for ONE workspace dir (CWD-independent).
# Two execution paths (co-dev cargo / release binary), like `_gen`.
_fixtures_gen_one dir:
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{dir}}"

	# The generator writes into an existing var/generated/ (new workspaces
	# have none yet); create it so generation never fails on a fresh dir.
	mkdir -p var/generated
	for what in hosts users network; do
		if [ -f {{dnfDir}}/../src/generator/Cargo.toml ] && command -v cargo >/dev/null 2>&1; then
			cargo run --quiet --manifest-path {{dnfDir}}/../src/generator/Cargo.toml -- "$what" >/dev/null
		elif command -v dnf-generator >/dev/null 2>&1; then
			dnf-generator "$what" >/dev/null
		else
			just _fail "Generator unavailable: enter devShell or provide src/generator/"
		fi
	done

# Regenerate var/generated for every test workspace (in place).
_fixtures_generate:
	#!/usr/bin/env bash
	set -euo pipefail
	shopt -s nullglob
	for d in {{dnfDir}}/tests/workspaces/*/configs/*/; do
		[ -f "${d}etc/config.yaml" ] || continue
		just _log "Generating ${d#{{dnfDir}}/}..." "FIXTURES"
		just _fixtures_gen_one "$d"
	done
	just _log "All test workspaces generated." "FIXTURES"

# Anti-drift: regenerate each workspace in a temp dir (skeleton symlinked by
# absolute path so profile resolution works) and diff against the committed
# output. Non-mutating: the working tree is never touched.
_fixtures_check:
	#!/usr/bin/env bash
	set -euo pipefail
	shopt -s nullglob
	rc=0
	skel="{{dnfDir}}/tests/workspaces/_skeleton"
	for d in {{dnfDir}}/tests/workspaces/*/configs/*/; do
		[ -f "${d}etc/config.yaml" ] || continue
		tmp=$(mktemp -d)
		mkdir -p "$tmp/etc"
		cp "${d}etc/config.yaml" "$tmp/etc/"
		ln -s "$skel/usr" "$tmp/usr"
		ln -s "$skel/dnf" "$tmp/dnf"
		just _fixtures_gen_one "$tmp"
		if ! diff -rq "${d}var/generated" "$tmp/var/generated" >/dev/null 2>&1; then
			just _err "Drift in ${d#{{dnfDir}}/} — run 'just fixtures generate'"
			rc=1
		fi
		rm -rf "$tmp"
	done
	[ "$rc" -eq 0 ] && just _log "No fixture drift." "FIXTURES"
	exit "$rc"

# (Rare) Regenerate the test sops key + encrypted secrets + self-signed TLS.
# Throwaway, INSECURE, committed: protects only fake test passwords.
_fixtures_gen_secrets:
	#!/usr/bin/env bash
	set -euo pipefail
	KEYS="{{fixturesDir}}/keys"
	SEC="{{fixturesDir}}/secrets"
	TLS="{{fixturesDir}}/tls"
	mkdir -p "$KEYS" "$SEC" "$TLS"

	# Throwaway age identity (committed on purpose, INSECURE).
	if [ ! -f "$KEYS/test-infra.age" ]; then
		just _log "Generating throwaway test age key..." "FIXTURES"
		age-keygen -o "$KEYS/test-infra.age"
	fi
	PUB=$(age-keygen -y "$KEYS/test-infra.age")

	# .sops.yaml targeting the test key only.
	{
		echo "keys:"
		echo "  - &test ${PUB}"
		echo "creation_rules:"
		echo "  - path_regex: \"[^/]+\\\\.yaml\$\""
		echo "    key_groups:"
		echo "    - age:"
		echo "      - *test"
	} > "$SEC/.sops.yaml"

	# Plaintext secrets the test modules need (default password + per-user hash).
	HASH=$(mkpasswd --method=bcrypt --rounds=12 "test")
	{
		echo "default-password: test"
		echo "default-password-hash: \"${HASH}\""
		echo "user:"
		echo "  nix:"
		echo "    password-hash: \"${HASH}\""
		echo "  darkone:"
		echo "    password-hash: \"${HASH}\""
		echo "smtp:"
		echo "  password: test"
	} > "$SEC/secrets.yaml"

	# In-place encrypt: cwd = $SEC so sops finds .sops.yaml and the filename
	# matches the path_regex creation rule.
	( cd "$SEC" && sops -e -i secrets.yaml )

	# Fixed self-signed TLS cert (stub ACME).
	if [ ! -f "$TLS/cert.pem" ]; then
		just _log "Generating self-signed TLS fixture..." "FIXTURES"
		openssl req -x509 -newkey rsa:2048 -nodes \
			-keyout "$TLS/key.pem" -out "$TLS/cert.pem" \
			-days 36500 -subj "/CN=test.local" \
			-addext "subjectAltName=DNS:test.local,DNS:*.test.local"
	fi
	just _log "Test fixtures generated under tests/fixtures/." "FIXTURES"

#==============================================================================
# Development
#==============================================================================

# format: fix + check + generate + format
[group('dev')]
clean: fix check generate format _fix_fs_permissions

# treefmt orchestrates formatters in parallel (via treefmt.toml)
[group('dev')]
format:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Full formatting..." "TREEFMT"
	treefmt --config-file {{dnfDir}}/assets/treefmt.toml --no-cache --quiet

# Fix with statix
[group('dev')]
fix:
	#!/usr/bin/env bash
	set -euo pipefail
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
	set -euo pipefail
	if [ ! -d "{{dir}}" ] ;then
		just _info "Skipping unknown directory {{dir}}..."
	else
		just _log "{{dir}} ➜ default.nix..." "GENERATOR"
		cd {{dir}}
		{
			echo "# DO NOT EDIT, this is a generated file."
			echo
			echo "{ imports = ["
			find . -name "*.nix" | sort | grep -v default.nix || true
			echo "];}"
		} > default.nix
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
	set -euo pipefail
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
		age-keygen -o {{sopsInfraKeyFile}}
	else
		just _info "Infra key file already exists." "SOPS"
	fi
	if [ ! -f {{sopsYamlFile}} ] ;then
		just _log "[SOPS] .sops.yaml file generation..."
		INF_PUB_KEY=$(age-keygen -y {{sopsInfraKeyFile}})

		# Dérivation directe depuis la pub SSH : ssh-to-age sur la pub key sort
		# un age1... en une ligne, sans parser le fichier admin keys.txt (qui
		# selon la version de ssh-to-age n'est pas toujours reconnu comme
		# identité native AGE-SECRET-KEY-1... par age-keygen -y).
		ADM_PUB_KEY=$(ssh-to-age -i "$HOME/.ssh/id_ed25519.pub")
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
		just _info ".sops.yaml file already exists." "SOPS"
	fi
	if [ ! -f {{sopsSecretsFile}} ] ;then
		just _log "We need a default password..." "SOPS"
		just passwd-default
		just push-key localhost
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

# Build DNF iso image
[group('install')]
build-iso arch="x86_64-linux":
	@just _log "Building local DNF ISO image..."
	sudo -i -u nix {{nix}} build .#nixosConfigurations.iso-{{arch}}.config.system.build.isoImage

# Edit sops secrets
[group('install')]
sops:
	#!/usr/bin/env bash
	set -euo pipefail
	just _sops_before_edit
	sudo -i -u nix EDITOR=vim sops {{sopsSecretsFile}}
	just _fix_fs_permissions

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

	# Commit all projects, but keep the root (.) for last: it must capture the
	# refreshed dnf lock, so it is committed only after update-dnf below.
	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			[ "$repo" == "." ] && continue
			just git-commit "{{msg}}" "$repo"
		done <<< "{{repos}}"

		# Dev mode only: sync the root flake.lock onto the freshly committed dnf
		# HEAD so the upcoming root commit pins a coherent framework revision.
		if [ -d "{{workDir}}/dnf/.git" ]; then
			just update-dnf
		fi
		just git-commit "{{msg}}" "."
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi
		git -C {{on}} add -A
		if git -C {{on}} diff --cached --quiet ;then
			just _info "Nothing to commit on {{on}}/" "GIT"
		else

			# Re-committing with the previous message means amend, not a new
			# commit (decided per-project, keeps the recipe idempotent).
			last=$(git -C {{on}} log -1 --format=%s 2>/dev/null || echo "")
			if [ "{{msg}}" == "$last" ]; then
				just _log "Amending {{on}}/ (same message)" "GIT"
				git -C {{on}} commit --amend --no-edit > /dev/null
			else
				just _log "Committing on {{on}}/" "GIT"
				git -C {{on}} commit -m "{{msg}}" > /dev/null
			fi
		fi
	fi

# Amend last commit in several projects with current changes (--no-edit)
[group('dev')]
git-amend on="all":
	#!/usr/bin/env bash
	set -euo pipefail

	# Amend all projects (root included): fold each tree's working changes into
	# its last commit, keeping its message.
	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			just git-amend "$repo"
		done <<< "{{repos}}"

		# Dev mode only: refresh the root lock onto the amended dnf HEAD, then
		# keep the root coherent with dnf. The pass above already committed the
		# root's own changes, so only the flake.lock delta remains here.
		if [ -d "{{workDir}}/dnf/.git" ]; then
			just update-dnf
			dnf_msg=$(git -C dnf log -1 --format=%s 2>/dev/null || echo "")
			root_msg=$(git -C . log -1 --format=%s 2>/dev/null || echo "")

			# Record the lock bump: nothing staged ⇒ already coherent; same
			# message ⇒ fold into the shared commit; different message ⇒ a
			# dedicated commit pins dnf so a root revert stays tied to a
			# compatible framework revision.
			git -C . add -A
			if git -C . diff --cached --quiet ;then
				just _info "Lock already coherent, nothing to align on ./" "GIT"
			elif [ "$dnf_msg" == "$root_msg" ]; then
				just _log "Folding dnf lock bump into ./ (aligned)" "GIT"
				git -C . commit --amend --no-edit --allow-empty > /dev/null
			else
				just _log "New ./ commit to pin dnf: $dnf_msg" "GIT"
				git -C . commit -m "$dnf_msg" > /dev/null
			fi
		fi
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

# Git status for one or all projects
[group('dev')]
git-status on="all":
	just git "status -s" {{on}} "Status of"

# Git diff for one or all projects
[group('dev')]
git-diff on="all":
	just git "diff" {{on}} "Diff of"

# Git push for one or all projects — check ahead before pushing
[group('dev')]
git-push on="all":
	#!/usr/bin/env bash
	set -euo pipefail

	if [ "{{on}}" == "all" ]; then
		while IFS= read -r repo; do
			[ -z "$repo" ] && continue
			just git-push "$repo"
		done <<< "{{repos}}"
	else
		if [ ! -d "{{on}}/.git" ]; then
			just _fail "Project '{{on}}' do not exists!";
		fi
		if ! upstream=$(git -C {{on}} rev-parse --abbrev-ref @{u} 2>/dev/null); then
			just _info "No upstream branch — set one with 'git push -u origin HEAD'" "GIT"
		elif [ "$(git -C {{on}} rev-list --count @{u}..HEAD 2>/dev/null || echo 0)" -eq 0 ]; then
			just _info "Nothing to push on {{on}}/" "GIT"
		else
			just _log "Pushing {{on}}/" "GIT"
			git -C {{on}} push
		fi
	fi

# Git pull for one or all projects
[group('dev')]
git-pull on="all":
	just git "pull" {{on}} "Pulling"

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
