# DNF just — repairs.

# Multi-reinstall bootloader (using colmena)
[group('fix')]
fix-boot on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just fix-boot "{{on}}"
	just _log "Fixing boot of {{on}}..."
	colmena exec --on "{{on}}" "sudo NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"

# Hosts installed before nixpkgs renumbered the GDM greeters keep the old
# UIDs: warning on every activation, two greeters on one UID. `check` (the
# default) writes nothing; `apply` skips a host with an open graphical session.
#
# `on` is a comma-separated list of hostnames, or `all` for every hive node.
#
# Realign gdm-greeter* UIDs on the nixpkgs ones (check | apply)
[group('fix')]
fix-gdm-greeters on mode='check':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just fix-gdm-greeters "{{on}}" "{{mode}}"
	case "{{mode}}" in check|apply) ;; *) just _fail "mode must be 'check' or 'apply'." ;; esac
	script="{{scriptsDir}}/fix-gdm-greeters.sh"
	[ -f "$script" ] || just _fail "missing $script"
	if [ "{{on}}" = "all" ] ;then
		nodes=$(just _hive-nodes)
	else
		nodes=$(echo "{{on}}" | tr ',' ' ')
	fi
	[ -n "$nodes" ] || just _fail "No target host."
	for node in $nodes ;do
		just _log "Checking GDM greeters on $node ({{mode}})..." "GDM"

		# Piped rather than copied: nothing is left behind on the host.
		ssh -o BatchMode=yes nix@"$node" "sudo MODE={{mode}} bash -s" < "$script" \
			|| just _warn "$node: fix-gdm-greeters exited non-zero."
	done
