# DNF just — roaming: reach a host plugged outside its own zone.

# Colmena addresses a node by its name, which DNS resolves to the host's HOME
# address — deploying into the void while the machine is plugged elsewhere.
# A stanza in the nix user's ssh config redirects it, and ssh, scp and colmena
# all honour it without knowing anything about zones. `full-install` clears it
# once the host is configured; call `roaming-clear` after a manual `configure`.
#
# No argument: show the current redirections.
#
# Route ssh to a host that sits outside its own zone.
[group('roaming')]
roaming host='' target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just roaming "{{host}}" "{{target}}"
	conf=~/.ssh/dnf-roaming.conf
	mkdir -p ~/.ssh
	touch "$conf" && chmod 600 "$conf"
	if [ -z "{{host}}" ] ;then
		if [ -s "$conf" ] ;then
			cat "$conf"
		else
			just _info "No roaming redirection." "SSH"
		fi
		exit 0
	fi
	t=$(just _resolve "{{host}}" "{{target}}")
	[ "$t" != "{{host}}" ] || just _fail "{{host}} resolves to itself: nothing to redirect."
	just roaming-clear "{{host}}"

	# The user config is read before /etc/ssh/ssh_config, so this stanza would
	# shadow the fleet policy set there (core.nix): restate it, or a roaming
	# host that was just reinstalled would fail on a changed key.
	cat >> "$conf" <<-EOF
		Host {{host}}
		  HostName $t
		  StrictHostKeyChecking no
		  UserKnownHostsFile /dev/null
	EOF

	# The `Include` that pulls this file in is declared by home-manager
	# (`programs.ssh.includes`): on an admin host that predates it, the file is
	# written but ssh never reads it — better said than silently ignored.
	if [ "$(ssh -G "{{host}}" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')" != "$t" ] ;then
		just _warn "ssh does not read dnf-roaming.conf: re-apply this admin host, then retry."
	fi
	just _log "{{host}} redirected to $t." "SSH"

# Drop the roaming redirection of one host (or of all of them)
[group('roaming')]
roaming-clear host='':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just roaming-clear "{{host}}"
	conf=~/.ssh/dnf-roaming.conf
	[ -f "$conf" ] || exit 0
	if [ -z "{{host}}" ] ;then
		: > "$conf"
		just _log "All roaming redirections dropped." "SSH"
		exit 0
	fi

	# `skip` stays set until the next Host line, dropping the whole stanza.
	tmp=$(mktemp)
	awk -v h="{{host}}" '$1 == "Host" { skip = ($2 == h) } !skip' "$conf" > "$tmp"
	mv "$tmp" "$conf"
	chmod 600 "$conf"
