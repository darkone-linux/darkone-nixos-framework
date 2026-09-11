# DNF just — repairs.

# Remove zshrc bkp to avoid error when replacing zshrc (deprecated)
[group('fix')]
fix-zsh on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just fix-zsh "{{on}}"
	just _log "Fixing ZSH on {{on}}..."
	colmena exec --on "{{on}}" "rm -f .zshrc.bkp"

# Multi-reinstall bootloader (using colmena)
[group('fix')]
fix-boot on:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just fix-boot "{{on}}"
	just _log "Fixing boot of {{on}}..."
	colmena exec --on "{{on}}" "sudo NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot"
