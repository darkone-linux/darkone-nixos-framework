# DNF just — repairs.

# Multi-reinstall bootloader (using colmena)
[group('fix')]
fix-boot on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just fix-boot "{{on}}"
	just _log "Fixing boot of {{on}}..."
	colmena exec --on "{{on}}" "sudo NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"
