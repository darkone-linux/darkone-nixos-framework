# Darkone framework — testing just file
# Imported by dnf/Justfile alongside assets/default.just.
#
# Variables (nix, dnfDir, fixturesDir, …) and helper recipes
# (_log, _err, _fail, …) are provided by default.just; always import both.

#==============================================================================
# Tests
#==============================================================================

# Run unit tests
[group('test')]
unit-tests:
	just _log "Running unit tests..." "TESTS"
	nix-unit --gc-roots-dir /tmp --flake .#libTests

# Run simulation tests (NixOS Test Driver).
#
# Usage:
#   just simulate              # list available scenarios
#   just simulate all          # run them all via `nix flake check`
#   just simulate full         # regenerate fixtures first, then `all`
#   just simulate <name>       # run a single named scenario
#
# Scenario names match the auto-discovery convention in
# `tests/scenarios/default.nix`: relative path with `/` → `-`, minus `.nix`
# (e.g. `modules/node-console-git.nix` ⇒ `just simulate modules-node-console-git`).
[group('test')]
simulate what="":
	#!/usr/bin/env bash
	set -euo pipefail
	system=$({{nix}} eval --raw --impure --expr 'builtins.currentSystem')
	case "{{what}}" in
	  "")
	    just _log "Available scenarios:" "SIMULATE"
	    {{nix}} eval --raw ".#checks.${system}" \
	      --apply 'cs: builtins.concatStringsSep "\n  " ([ "" ] ++ builtins.attrNames cs)'
	    echo; echo
	    just _log "Run one:   just simulate <name>" "SIMULATE"
	    just _log "Run all:   just simulate all" "SIMULATE"
	    just _log "Full run:  just simulate full" "SIMULATE"
	    ;;
	  all)
	    just _log "Running all simulation tests..." "SIMULATE"
	    {{nix}} flake check --quiet
	    ;;
	  full)
	    just _log "Regenerating fixtures, then running everything..." "SIMULATE"
	    just _fixtures_generate
	    {{nix}} flake check --quiet
	    ;;
	  *)
	    just _log "Running {{what}}..." "SIMULATE"
	    {{nix}} build ".#checks.${system}.{{what}}" --no-link
	    ;;
	esac

# Interactive driver for one scenario (Python REPL inside the test driver).
# Useful to step through a failing scenario: `start_all()`, then drive nodes
# (`node1.succeed(...)`, `node1.shell_interact()`, ...). Pipe a heredoc on
# stdin for non-interactive smoke-runs.
[group('test')]
simulate-debug what:
	#!/usr/bin/env bash
	set -euo pipefail
	just _log "Interactive driver for {{what}}..." "SIMULATE"
	system=$({{nix}} eval --raw --impure --expr 'builtins.currentSystem')
	{{nix}} run ".#checks.${system}.{{what}}.driverInteractive"

# Manage test fixtures: generate | check | gen-secrets
[group('test')]
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
	# `disko` is included so workspaces declaring a host with a disko profile
	# (L4 install tier) get their `usr/machines/<host>/` laid down; for
	# workspaces without such a host the disko pass is a no-op.
	mkdir -p var/generated
	for what in hosts users network disko; do
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

# Anti-drift: regenerate each workspace in a temp dir and diff against the
# committed output. Non-mutating: the working tree is never touched.
#
# Two layouts coexist:
#   - usr/dnf as a symlink to the shared `_skeleton` → re-symlink in tmp;
#   - usr/dnf as a real directory (L4 disko variants own their
#     `usr/machines/<host>/`) → copy with `cp -aL` so disko writes stay
#     inside tmp instead of being followed through to the skeleton.
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
		for sub in usr dnf; do
			if [ -L "${d}${sub}" ]; then
				ln -s "$skel/$sub" "$tmp/$sub"
			else
				cp -aL "${d}${sub}" "$tmp/$sub"
			fi
		done
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
