# Darkone framework — consumer project Justfile
# darkone@darkone.yt
#
# Imported by the consumer root Justfile (./Justfile). Imports common.just
# which provides shared parameters, helper functions, check/dev recipes,
# generators, and git helpers.

import 'common.just'

# Project-specific param: the repo-side gitignore path for secrets.
secretsGitIgnore := secretsDir + '/.gitignore'
sopsAdminKeyDir := home_directory() + '/.config/sops/age'
sopsAdminKeyFile := sopsAdminKeyDir + '/keys.txt'
sopsYamlFile := secretsDir + '/.sops.yaml'
sopsInfraTargetFile := sopsInfraTargetDir + '/infra.key'
dnfInstallDir := '/mnt/dnf-install'

# Deploy build location. Empty (default): build each node closure on the host
# running just, then push it — a derivation compiles once and the deployer's
# harmonia re-serves it to the whole fleet. Non-empty: build on each target
# (use for an arch the deployer cannot build natively, e.g. aarch64 rpi hosts).
buildOnTarget := ''

alias a := apply
alias al := apply-local
alias av := apply-verbose
alias e := enter
alias rd := remote-desktop

#==============================================================================
# Development
#==============================================================================

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

# Update all flake inputs (dnf/ + root), commit and align locks
[group('dev')]
update-flake:
	#!/usr/bin/env bash
	set -euo pipefail

	# Co-development only: `dnf/` is a git checkout carrying its own lock, and
	# the dual-repo commit helpers of dev.just are imported. In release mode
	# `dnf/` is a read-only store symlink (or absent) — only the root lock moves.
	if [ ! -d "{{workDir}}/dnf/.git" ]; then
		just _log "Updating flake inputs..." "FLAKE"
		cd {{workDir}} && {{nix}} flake update
		exit 0
	fi
	just _log "Updating dnf/ flake inputs..." "FLAKE"
	(cd {{workDir}}/dnf && {{nix}} flake update)
	last_msg=$(git -C {{workDir}}/dnf log -1 --format=%s 2>/dev/null || echo "")
	if [[ "$last_msg" == "update(flake):"* ]]; then
		just _log "Amending existing update(flake) commit..." "FLAKE"
		just amend
	else
		just commit "update(flake): Regular NixOS Update"
	fi
	just _log "Updating root flake inputs..." "FLAKE"
	cd {{workDir}} && {{nix}} flake update
	just amend

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

#==============================================================================
# Installation
#==============================================================================

# Effective etc/config.yaml entry of one CONCRETE host, as JSON.
#
# A `hosts:` entry is not always a host: a `range:` group declares a template
# and its bounds (`fl-%'02s` + `range: [1, 2]`), a `hosts:` group a `%s`
# template over named sub-hosts. Only the generator expands them, into
# var/generated/hosts.nix. So the obvious `select(.hostname == "fl-01")` on the
# raw config matches NOTHING, and every recipe keyed on the config by host name
# saw half the fleet as unknown (`just luks fl-01` refused to run on a host it
# had itself encrypted) or as declaring nothing (`just install` and its DHCP
# reservation guard).
#
# Expansion mirrors `load_hosts` in the generator (nix_generator/configuration.rs):
# same template syntax, same keys inherited from the group, same per-index
# `mac:` map. Prints nothing (exit 0) when no group yields that name — the
# caller decides whether that is fatal.
_host_conf host:
	#!/usr/bin/env bash
	set -euo pipefail
	cfg={{workDir}}/etc/config.yaml
	host="{{host}}"

	# `%'<pad><width>s` first, then `%d` and `%s`: the generator's apply_template.
	tpl() {
		local out=$1 i=$2 pad width value
		while [[ $out =~ %\'(.)([0-9]+)s ]] ;do
			pad=${BASH_REMATCH[1]} ; width=${BASH_REMATCH[2]} ; value=$i
			while [ ${#value} -lt "$width" ] ;do value="$pad$value" ;done
			out=${out/"${BASH_REMATCH[0]}"/$value}
		done
		out=${out//%d/$i}
		printf '%s' "${out//%s/$i}"
	}

	# One pass over the groups: index, hostname template, range bounds, sub-host
	# keys. Joined with '|' rather than a tab, which is IFS whitespace: bash would
	# collapse the empty fields of a static host and shift every column.
	group='' ; index='' ; key=''
	while IFS='|' read -r g name from to keys ;do
		[ -n "$name" ] || continue
		if [ -n "$from" ] ;then
			for ((i = from; i <= to; i++)) ;do
				if [ "$(tpl "$name" "$i")" = "$host" ] ;then group=$g ; index=$i ; break ;fi
			done
		elif [ -n "$keys" ] ;then
			for k in ${keys//,/ } ;do
				if [ "${name//%s/$k}" = "$host" ] ;then group=$g ; key=$k ; break ;fi
			done
		elif [ "$name" = "$host" ] ;then
			group=$g
		fi
		[ -z "$group" ] || break
	done < <(yq -r '.hosts | to_entries | .[] | [.key, (.value.hostname // ""), (.value.range[0] // ""), (.value.range[1] // ""), ((.value.hosts // {}) | keys | join(","))] | join("|")' "$cfg")
	[ -n "$group" ] || exit 0

	if [ -n "$index" ] ;then

		# Range member: templated hostname/name/zone, MAC read from the indexed
		# map. `ipv4`, `arch`, `aliases` and `services` stay group-level, a member
		# never inherits them (cf. build_range_entry).
		HN="$host" \
		NM="$(tpl "$(yq -r ".hosts[$group].name // \"\"" "$cfg")" "$index")" \
		ZN="$(tpl "$(yq -r ".hosts[$group].zone // \"\"" "$cfg")" "$index")" \
		MC="$(yq -r ".hosts[$group].mac.\"$index\" // \"\"" "$cfg")" \
			yq -o=json ".hosts[$group]
				| del(.range, .hosts, .ipv4, .arch, .aliases, .services)
				| .hostname = strenv(HN) | .name = strenv(NM)
				| .zone = strenv(ZN) | .mac = strenv(MC)" "$cfg"
	elif [ -n "$key" ] ;then

		# List member: its own entry, the group keys winning over it, both names
		# templated on the sub-host (cf. build_list_entry).
		gname=$(yq -r ".hosts[$group].name // \"\"" "$cfg")
		sname=$(yq -r ".hosts[$group].hosts.\"$key\".name // \"$key\"" "$cfg")
		HN="$host" NM="${gname//%s/$sname}" \
			yq -o=json "(.hosts[$group].hosts.\"$key\" | del(.profile, .users, .groups, .features, .tags, .disko))
				* (.hosts[$group] | pick([\"profile\", \"users\", \"groups\", \"features\", \"tags\", \"disko\"]))
				| .hostname = strenv(HN) | .name = strenv(NM)" "$cfg"
	else
		yq -o=json ".hosts[$group]" "$cfg"
	fi

# Address to reach {{host}} from the machine running just.
#
# Its own name when both sit in the same zone. Otherwise the address the local
# zone reserves for it: every gateway holds a DHCP reservation for each known
# fleet MAC that is not native to its zone (`zone.roaming`, generated), so a
# machine plugged anywhere is predictable before it has even booted.
#
# The local zone is the one whose gateway actually routes this machine, NOT the
# zone it is declared in — an admin laptop is precisely the thing that moves.
# Declaration is only the fallback (deploying over the VPN, gateway itself).
#
# Falls back to the host name when nothing matches: a host with no declared MAC
# is simply not reachable outside its zone.
#
# A reservation is an expectation, not evidence, so the roaming address is
# probed before being returned — see the comment on the probe below.
_target host:
	#!/usr/bin/env bash
	set -euo pipefail
	gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)
	addr=$({{nix}} eval --raw --impure --expr '
	  let
	    hosts = import {{workDir}}/var/generated/hosts.nix;
	    network = import {{workDir}}/var/generated/network.nix;
	    findHost = n:
	      let matches = builtins.filter (h: h.hostname == n) hosts;
	      in if matches == [ ] then null else builtins.head matches;
	    localZones = builtins.filter (z: z.name != "www") (builtins.attrValues network.zones);
	    routedBy = builtins.filter (z: (z.gateway.lan.ip or "") == "'"$gw"'") localZones;
	    me = findHost "'"$(hostname -s)"'";
	    here =
	      if routedBy != [ ] then builtins.head routedBy
	      else if me != null then network.zones.${me.zone} or null
	      else null;
	    target = findHost "{{host}}";
	  in
	  if here == null || target == null || target.zone == here.name
	  then "{{host}}"
	  else here.roaming."{{host}}" or "{{host}}"
	')

	# The roaming reservation says where the host WOULD be if plugged in here.
	# During an install it is right — the machine is on the bench, answering on
	# 22. Once it is back home and reached over the VPN it is a dead address,
	# and every management recipe aimed at it: `just enter` gave up, `just luks`
	# warned and exited 0 while colmena, which addresses nodes by name, still
	# deployed happily. Order below: trust the reservation only if something
	# answers there, otherwise the name if the host responds (2222 included —
	# an encrypted host waiting in its initrd is up, just not booted), and keep
	# the reservation as the last word so a machine not powered on yet still
	# resolves to the address its installer will appear on.
	up() { timeout 2 bash -c ": < /dev/tcp/$1/$2" 2>/dev/null ; }
	if [ "$addr" = "{{host}}" ] ;then
		echo "{{host}}"
	elif up "$addr" 22 ;then
		echo "$addr"
	elif up "{{host}}" 22 || up "{{host}}" 2222 ;then
		echo "{{host}}"
	else
		echo "$addr"
	fi

# Resolve a recipe's `target`/`ip` parameter: 'auto' asks `_target`.
_resolve host target:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ "{{target}}" = "auto" ] ;then
		just _target "{{host}}"
	else
		echo "{{target}}"
	fi

# Wait for a target to come up (or go down) on ssh.
#
# Deliberately not `ping`: a gateway drops ICMP everywhere but on its LAN
# bridge (cf. `modules/service/dnsmasq.nix`), so a box reached from another
# zone never answers a ping while its ssh port is wide open.
_wait-ssh target state='up' timeout='600':
	#!/usr/bin/env bash
	set -euo pipefail
	deadline=$(( $(date +%s) + {{timeout}} ))
	printf 'Waiting for {{target}} to be {{state}}'
	while : ;do
		if timeout 2 bash -c ': < /dev/tcp/{{target}}/22' 2>/dev/null ;then
			current=up
		else
			current=down
		fi
		[ "$current" != "{{state}}" ] || break
		if [ "$(date +%s)" -ge "$deadline" ] ;then
			printf ' timeout\n'
			just _fail "{{target}} is still not {{state}} after {{timeout}}s."
		fi
		printf '.'
		sleep 2
	done
	printf ' OK\n'

# Every address {{host}} may answer on, most specific first:
#
#   1. `ip`, the address the caller already used (typically the installer's);
#   2. the fixed address of its own zone — what DNS publishes fleet-wide;
#   3. the address the locally-routing zone reserves for it (roaming table);
#   4. its name, resolved by the local gateway.
#
# `_target` picks ONE address to start from; this lists them all, because a
# machine does not always come back where it left. Probing the whole list is
# what makes an install survive a renumbering.
_candidates host ip='':
	#!/usr/bin/env bash
	set -euo pipefail
	gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)
	addrs=()
	case "{{ip}}" in
		''|auto) ;;
		*) addrs+=("{{ip}}") ;;
	esac

	# Same zone detection as `_target`: the zone that actually routes THIS
	# machine, falling back to the one it is declared in.
	mapfile -t derived < <({{nix}} eval --raw --impure --expr '
	  let
	    hosts = import {{workDir}}/var/generated/hosts.nix;
	    network = import {{workDir}}/var/generated/network.nix;
	    findHost = n:
	      let matches = builtins.filter (h: h.hostname == n) hosts;
	      in if matches == [ ] then null else builtins.head matches;
	    localZones = builtins.filter (z: z.name != "www") (builtins.attrValues network.zones);
	    routedBy = builtins.filter (z: (z.gateway.lan.ip or "") == "'"$gw"'") localZones;
	    me = findHost "'"$(hostname -s)"'";
	    here =
	      if routedBy != [ ] then builtins.head routedBy
	      else if me != null then network.zones.${me.zone} or null
	      else null;
	    target = findHost "{{host}}";
	  in
	  (if target == null then "" else target.ip or "")
	  + "\n"
	  + (if here == null then "" else here.roaming."{{host}}" or "")
	  + "\n"
	')
	addrs+=("${derived[@]}")
	addrs+=("{{host}}")
	printf '%s\n' "${addrs[@]}" | awk 'NF && !seen[$0]++'

# Wait until one of `_candidates` answers, then print "<address> <port>".
#
# Deliberately not `ping`: a gateway drops ICMP everywhere but on its LAN
# bridge (cf. `modules/service/dnsmasq.nix`), so a box reached from another
# zone never answers a ping while its ssh port is wide open.
#
# 2222 counts as an answer: an encrypted host waiting in its initrd is up, just
# not booted — the caller decides what to do with it (see `just unlock`).
_wait-any host ip='' ports='22 2222' timeout='600':
	#!/usr/bin/env bash
	set -euo pipefail
	mapfile -t addrs < <(just _candidates "{{host}}" "{{ip}}")
	deadline=$(( $(date +%s) + {{timeout}} ))
	printf 'Waiting for {{host}} on %s' "${addrs[*]}" >&2
	while : ;do
		for addr in "${addrs[@]}" ;do
			for port in {{ports}} ;do
				if timeout 2 bash -c ": < /dev/tcp/$addr/$port" 2>/dev/null ;then
					printf ' OK (%s:%s)\n' "$addr" "$port" >&2
					echo "$addr $port"
					exit 0
				fi
			done
		done
		if [ "$(date +%s)" -ge "$deadline" ] ;then
			printf ' timeout\n' >&2
			just _fail "{{host}} answered on none of: ${addrs[*]} (after {{timeout}}s)."
		fi
		printf '.' >&2
		sleep 2
	done

# Colmena addresses a node by its name, which DNS resolves to the host's HOME
# address — deploying into the void while the machine is plugged elsewhere.
# A stanza in the nix user's ssh config redirects it, and ssh, scp and colmena
# all honour it without knowing anything about zones. `full-install` clears it
# once the host is configured; call `roaming-clear` after a manual `configure`.
#
# No argument: show the current redirections.
#
# Route ssh to a host that sits outside its own zone.
[group('install')]
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
[group('install')]
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

# `target` is the network address to reach the node; 'auto' asks `_target`,
# which returns the host name in its own zone and the reserved roaming address
# elsewhere. The machine identity stays {{host}} whatever the address used.
#
# Copy pub key to the node (nix user must exist)
[group('install')]
copy-id host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	t=$(just _resolve "{{host}}" "{{target}}")
	if sudo -i -u nix ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o BatchMode=yes nix@"$t" "true"; then
		just _info "SSH key already exists for {{host}}, continue..." "SSH"
	else

		# No bootstrap left to attempt: core.nix disables password and
		# keyboard-interactive auth and drops `~/.ssh/authorized_keys`, so
		# ssh-copy-id has neither a way in nor a file sshd would read. The
		# deploy key is declarative (`usr/secrets/nix.pub`).
		just _fail "nix@{{host}} ($t) refuses the deploy key. Check usr/secrets/nix.pub, then re-apply from a channel that still works (console, initrd sshd on 2222)."
	fi

	# Gateways pull TLS certs from the HCS over SSH as `nix` (sync-caddy-certs),
	# so they need the shared deploy PRIVATE key, not just authorized_keys.
	# Restrict it to gateways: admin hosts already hold it (configure-admin-host
	# generates it locally), any other host must never carry it.
	profile=$({{nix}} eval --impure --raw \
		--expr '(builtins.head (builtins.filter (h: h.hostname == "{{host}}") (import {{workDir}}/var/generated/hosts.nix))).profile' 2>/dev/null || echo "")
	if [ "$profile" = "gateway" ] ;then
		just _log "Pushing nix deploy key (gateway TLS cert sync)..." "SSH"
		sudo -i -u nix scp ~nix/.ssh/id_ed25519 ~nix/.ssh/id_ed25519.pub nix@"$t":.ssh/
		sudo -i -u nix ssh nix@"$t" 'chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519 && chmod 644 ~/.ssh/id_ed25519.pub'
	fi

# Generate every internal secret the fleet declares (idempotent, silent when
# there is nothing to create).
#
# The list is NOT maintained here: `<workDir>#secretsPlan` collects the
# `sops.secrets` of every host and classifies each entry (dnf/lib/secrets.nix),
# so enabling a service is enough to bring its secrets along. Only what DNF can
# invent on its own is created; human, hardware and third-party secrets stay
# manual (`just sops`, `just passwd`, `just luks`, `just yubikey`,
# `just configure-alert-bot`). An existing entry is never overwritten.
_gen-secrets:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just _gen-secrets
	just _sops_before_edit
	n=$(WORKDIR="{{workDir}}" SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
		bash {{assetsDir}}/scripts/just-generate-secrets.sh)
	case "$n" in
		skip) ;;
		0) just _info "Secrets already generated." "SOPS" ;;
		*) just _log "$n secret(s) generated." "SOPS" ;;
	esac

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

		# The infra key lives under /etc/sops/age (not in the repo). Own the
		# directory as the nix deploy user so the admin tooling can read/manage
		# the key; sops-nix still reads it as root at activation.
		sudo mkdir -p {{sopsInfraTargetDir}}
		sudo chown nix {{sopsInfraTargetDir}}
		age-keygen -o {{sopsInfraKeyFile}}
		chmod 600 {{sopsInfraKeyFile}}
	else
		just _info "Infra key file already exists." "SOPS"
	fi
	if [ ! -f {{sopsYamlFile}} ] ;then
		just _log "[SOPS] .sops.yaml file generation..."
		just _regen-sops-yaml
	else
		just _info ".sops.yaml file already exists." "SOPS"
	fi
	if [ ! -f {{sopsSecretsFile}} ] ;then
		just _log "We need a default password..." "SOPS"
		just passwd-default
	else
		just _info "Default secret file already exists." "SOPS"
	fi

	# Harmonia binary-cache signing key: when the public key is missing,
	# (re)generate the keypair, store the private key in sops and keep the
	# public key committed (read by nix-cache to trust harmonia-signed paths).
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

	# Everything the declared services need and nobody has to know: OIDC client
	# secrets, backup credentials, service-to-service tokens... Re-run this
	# recipe after enabling a service to converge the new entries.
	just _gen-secrets
	just _fix_fs_permissions
	just _done

# `target`: network address to reach the node ('auto' = resolved by `_target`).
# The extracted config is always stored under the machine identity {{host}}.
#
# Extract hardware config from host
[group('install')]
copy-hw host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	t=$(just _resolve "{{host}}" "{{target}}")
	just _log "Extracting hardware information..."
	mkdir -p usr/machines/{{host}}
	sudo -i -u nix ssh nix@"$t" "sudo nixos-generate-config --no-filesystems --show-hardware-config" > {{workDir}}/usr/machines/{{host}}/hardware-configuration.nix
	nixfmt -s usr/machines/{{host}}/hardware-configuration.nix

# `target`: network address to reach the node ('auto' = resolved by `_target`).
#
# Push the infrastructure key to the host
[group('install')]
push-key host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just push-key "{{host}}" "{{target}}"
	t=$(just _resolve "{{host}}" "{{target}}")
	just _check_infra_admin
	just _log "Pushing infra key file..." "SOPS"
	ssh nix@"$t" 'sudo mkdir -p {{sopsInfraTargetDir}}'
	ssh nix@"$t" 'sudo chown -R nix {{sopsInfraTargetDir}}'
	scp {{sopsInfraKeyFile}} nix@"$t":{{sopsInfraTargetFile}}
	ssh nix@"$t" 'sudo chown -R root {{sopsInfraTargetDir}}'
	ssh nix@"$t" 'sudo chmod 600 {{sopsInfraTargetFile}}'

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

	# A run that died between `configure` and its final cleanup leaves this host
	# redirected to an install-time address, host key checking disabled, for
	# every later ssh and colmena. Start from a clean slate.
	just roaming-clear "{{host}}"
	just clean
	just _log "Preparation..."
	if [ ! -f "./usr/machines/{{host}}/default.nix" ]; then
		just _fail "Host '{{host}}' not found. Check it exists and has a disko config in etc/config.yaml."
	fi
	echo "{ }" > ./usr/machines/{{host}}/hardware-configuration.nix

	# The install ends on a reboot, and the rest of the chain has to find the
	# machine again. dnsmasq keys its reservation on the MAC and DNS publishes
	# the fixed address of the host's zone: without both, the installed system
	# takes a random lease and everything after this points at nothing.
	hostconf=$(just _host_conf "{{host}}")
	mac=$(echo "$hostconf" | yq -p=json -r '.mac // ""')
	zonespec=$(echo "$hostconf" | yq -p=json -r '.zone // ""')
	extip=$(echo "$hostconf" | yq -p=json -r '.ipv4.external // ""')

	# Only where a gateway actually serves the zone: the very first host of a
	# network has nothing to reserve an address for it, and is installed on an
	# address given by hand.
	zonegw=$({{nix}} eval --impure --raw \
		--expr "(import {{workDir}}/var/generated/network.nix).zones.\"${zonespec%%:*}\".gateway.hostname or \"\"" 2>/dev/null || echo "")
	if [ -z "$extip" ] && [ -n "$zonegw" ] ;then
		if [ -z "$mac" ] ;then
			just _err "{{host}} has no 'mac:' in etc/config.yaml: no DHCP reservation, so it will"
			just _err "come back on a random address after the reboot that ends the install."
			just _err "Boot the installer, then: just host-info {{host}} <its-current-ip>"
			just _fail "Declare mac + a fixed 'zone: <zone>:<x.y>', then 'just apply $zonegw'."
		fi
		case "$zonespec" in
			*:*) ;;
			*) just _fail "{{host}} has no fixed address: use 'zone: <zone>:<x.y>' in etc/config.yaml, then 'just apply $zonegw'." ;;
		esac
	elif [ -z "$extip" ] && [ -z "$mac" ] ;then
		just _warn "No gateway in zone '${zonespec%%:*}': {{host}} keeps whatever address it was given."
	fi

	TARGET_HOST=$(just _resolve "{{host}}" "{{ip}}")

	# nixos-anywhere pins --target-host for the whole run and has no option to
	# follow a renumbering (only a port change, --post-kexec-ssh-port). So the
	# address must already be one the machine will KEEP: installing over an OS
	# still holding an older dynamic lease strands the run the moment the
	# installer re-runs DHCP and lands on the reserved address.
	#
	# `_candidates` without an explicit ip lists exactly the addresses the host
	# legitimately answers on — its own, its roaming reservation, its name — so
	# a host installed while visiting another zone still passes.
	if [ -n "$zonegw" ] ;then
		expected=$(just _candidates "{{host}}")
		if ! printf '%s\n' "$expected" | grep -qx -- "$TARGET_HOST" ;then
			just _err "Installing {{host}} on $TARGET_HOST, which is not an address it keeps."
			just _err "The installer re-runs DHCP and will move to its reservation mid-install,"
			just _err "leaving nixos-anywhere talking to nothing. Expected: $(echo $expected)."
			just _fail "Put the machine on its reserved address first (reboot it), then install there."
		fi
	fi
	just _log "We need to add, commit and build..."

	# Offline half of the LUKS provisioning, BEFORE the build: the module only
	# wakes up for a host listed in usr/secrets/luks.json, and the initrd host
	# key it needs must exist in sops so `--extra-files` can stage it below.
	# No-op on an unencrypted host.
	just luks "{{host}}" pre

	# Staged before the sops step on purpose: `_gen-secrets` evaluates the flake
	# to know which secrets the fleet needs, and nix only sees files git already
	# knows about — a brand new host would stay invisible to the very step that
	# must create its credentials.
	git add .
	just _log "Sops updates..."
	just _gen-secrets
	just _fix_fs_permissions
	git add . && (git diff --cached --quiet || git commit -m "New host {{host}} dnf installation") && git reset
	just _log "Launching installation ({{do}})..."
	if [ "{{do}}" == "test" ]; then

		# nixos-anywhere refuses --vm-test together with --extra-files or
		# --disk-encryption-keys, so this mode exercises neither the staged
		# secrets nor the LUKS format key.
		if grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/disko.nix 2>/dev/null ;then
			just _warn "vm-test cannot supply the LUKS format key: disko will fail on {{host}}."
		fi
		{{nix}} run github:nix-community/nixos-anywhere -- --flake .#{{host}} --vm-test
	elif [ "{{do}}" == "install" ] ;then
		NIX_HOME=$(getent passwd nix | cut -d: -f6)
		mkdir -p {{workDir}}/usr/machines/{{host}}
		sudo chown -R nix {{workDir}}/usr/machines/{{host}}
		sudo chown -R nix /etc/nixos/.git

		# Everything the FIRST boot needs, staged into /mnt before nixos-install
		# runs. nixos-anywhere untars it as root with --no-same-owner, so modes
		# are what matters here, not ownership. Lives in /run: never on disk.
		stage=$(sudo mktemp -d -p /run dnf-extra-XXXXXX)
		pwfile=$(sudo mktemp -p /run dnf-luks-XXXXXX)
		trap 'sudo rm -rf "$stage" "$pwfile"' EXIT
		sudo chown nix "$stage" "$pwfile"
		sudo chmod 700 "$stage" ; sudo chmod 600 "$pwfile"

		# sops age key: without it the first activation decrypts nothing —
		# `just push-key` only runs later, at `just configure`.
		sudo install -D -m 600 {{sopsInfraKeyFile}} "$stage{{sopsInfraTargetFile}}"
		sudo chown -R nix "$stage"

		naflags=()
		if grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/disko.nix 2>/dev/null ;then

			# The initrd host key must be on the disk before nixos-install
			# embeds it in the bootloader: that is what makes the very first
			# boot answer on 2222 (dnf/modules/system/luks.nix). base64 in sops
			# so the key round-trips byte for byte.
			sudo -u nix mkdir -p "$stage/var/lib/luks-initrd"
			sudo -u nix env SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
				sops -d --extract '["luks"]["{{host}}"]["initrd-key"]' {{sopsSecretsFile}} \
				| base64 -d | sudo -u nix tee "$stage/var/lib/luks-initrd/ssh_host_ed25519_key" >/dev/null
			sudo -u nix env SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
				sops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' {{sopsSecretsFile}} \
				| sudo -u nix tee "$stage/var/lib/luks-initrd/ssh_host_ed25519_key.pub" >/dev/null
			sudo chmod 700 "$stage/var/lib/luks-initrd"
			sudo chmod 600 "$stage/var/lib/luks-initrd/ssh_host_ed25519_key"
			sudo chmod 644 "$stage/var/lib/luks-initrd/ssh_host_ed25519_key.pub"

			# disko formats with the shared fleet passphrase (passwordFile in
			# dnf/hosts/disko/luks-*.nix), so the format keyslot IS the shared
			# keyslot: nothing to type here, nothing to retype at `just luks`.
			# Piped, never captured: `$(...)` would eat a trailing byte and
			# cryptsetup compares raw file contents.
			sudo -u nix env SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
				sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} \
				| sudo -u nix tee "$pwfile" >/dev/null
			[ -s "$pwfile" ] || just _fail "Empty shared LUKS passphrase in sops."
			naflags+=(--disk-encryption-keys /tmp/dnf-luks.key "$pwfile")
		fi

		sudo -i -u nix {{nix}} run github:nix-community/nixos-anywhere -- \
			--copy-host-keys \
			--flake "{{workDir}}#{{host}}" \
			-i "${NIX_HOME}/.ssh/id_ed25519" \
			--extra-files "$stage" \
			"${naflags[@]}" \
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

	# Local counterpart of `install`'s --disk-encryption-keys: disko reads the
	# shared fleet passphrase from the path its `passwordFile` names, so the
	# format keyslot is the managed one. Piped, never captured: cryptsetup
	# compares raw file contents. No-op on an unencrypted layout.
	if grep -q '"luks"' ./usr/machines/{{host}}/disko.nix 2>/dev/null ;then
		trap 'sudo rm -f /tmp/dnf-luks.key' EXIT
		SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} \
			sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} \
			| sudo tee /tmp/dnf-luks.key >/dev/null
		sudo chmod 600 /tmp/dnf-luks.key
		[ -s /tmp/dnf-luks.key ] || just _fail "Empty shared LUKS passphrase in sops."
	fi
	sudo {{nix}} run github:nix-community/disko -- \
	  --mode disko \
	  --root-mountpoint {{dnfInstallDir}} ./usr/machines/{{host}}/disko.nix
	just _log "NixOS DNF installation..."
	sudo nixos-install --flake '.#{{host}}' --root {{dnfInstallDir}} --no-root-password
	just _log "Unmounting new system..."
	sudo umount -R {{dnfInstallDir}}
	sudo rmdir {{dnfInstallDir}}
	just _log "End of key installation"

# Read the MAC of a machine so it can be declared before being installed.
#
# `target` is usually the dynamic lease the installer picked up: a host with no
# `mac:` yet has no reservation, so it cannot be reached by name. Declare the
# address it prints, give the host a fixed `zone: "<zone>:<x.y>"` outside the
# DHCP pool, then `just apply <gateway>` — from there the installer and the
# installed system land on the very same address.
#
# Show the mac address of a host (to declare it in etc/config.yaml)
[group('install')]
host-info host target='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	t=$(just _resolve "{{host}}" "{{target}}")
	probe="ip -o link show up | grep -v 'lo:' | head -n 1 | sed 's/^.* \([0-9a-f:]*\) brd .*$/\1/'"

	# `nixos` on purpose: the very machine whose MAC is still unknown is the one
	# running the DNF installer image, where the account is `nixos`, not `nix`.
	MAC_ADDR=""
	for u in nix nixos ;do
		MAC_ADDR=$(sudo -i -u nix ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			-o PasswordAuthentication=no -o PubkeyAuthentication=yes -o ConnectTimeout=5 \
			"$u"@"$t" "$probe" 2>/dev/null || true)
		[ -z "$MAC_ADDR" ] || break
	done
	[ -n "$MAC_ADDR" ] || just _fail "Could not read a MAC from $t (tried nix@ and nixos@)."
	just _log "You can register the mac address in etc/config.yaml: {{GREEN}}$MAC_ADDR{{NORMAL}}"

# Auto-switching here means the chained `copy-id` / `copy-hw` / `push-key`
# already inherit the nix user — their own guards short-circuit cleanly.
#
# `ip`: network address to reach the node ('auto' = resolved by `_target`).
# Configuring a host that sits outside its own zone also installs the ssh
# redirection, so the `apply` that follows reaches it instead of its home
# address; `just roaming-clear {{host}}` drops it once the host is back home.
#
# New host: ssh cp id, extr. hw, push infra key, clean, info
[group('install')]
configure host ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	t=$(just _resolve "{{host}}" "{{ip}}")
	just copy-id "{{host}}" "$t"
	just copy-hw "{{host}}" "$t"
	just push-key "{{host}}" "$t"

	# LUKS provisioning is a no-op on unencrypted hosts and idempotent on
	# encrypted ones (secrets/manifest/initrd key created only when missing).
	just luks "{{host}}" '' "$t"

	# Only a genuinely away address deserves a redirection. `full-install`
	# always hands over an IP — whatever `_wait-any` found — so testing against
	# the name alone installed one on EVERY install, including for a host
	# sitting at home at its own declared address. The stanza disables host key
	# checking for good, so an unnecessary one is not harmless.
	home=$({{nix}} eval --raw --impure --expr '
	  let
	    hosts = import {{workDir}}/var/generated/hosts.nix;
	    matches = builtins.filter (h: h.hostname == "{{host}}") hosts;
	  in if matches == [ ] then "" else (builtins.head matches).ip or ""
	' 2>/dev/null || echo "")
	if [ "$t" != "{{host}}" ] && [ "$t" != "$home" ] ;then
		just roaming "{{host}}" "$t"
	fi
	just _log "If no error occurs, do not forget to commit and apply:"
	just _log "git add . && git commit -m 'Installing new host {{host}}'"
	just _log "just apply-verbose {{host}}"
	just host-info "{{host}}" "$t"

# One address for the whole run: `_target` gives the host name when it is
# installed at home, and the address its host zone reserves for it otherwise.
# The reservation is a DHCP one, keyed on the MAC, so the installer and the
# installed system land on the very same address — nothing to type, nothing to
# guess. Requires the local gateway to be up to date (`just apply <gateway>`)
# when the host has just been declared in etc/config.yaml.
#
# New host: full installation (install, configure, apply)
[group('install')]
full-install host user='nixos' ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	target=$(just _resolve "{{host}}" "{{ip}}")
	if [ "$target" != "{{host}}" ] ;then
		just _log "{{host}} sits outside its own zone, reachable at $target." "INSTALL"
	fi
	just install {{host}} {{user}} "$target"
	just _log "Waiting for reboot..."

	# nixos-anywhere returns while the installer still answers on ssh: watch the
	# machine go down before waiting for it to come back, or `configure` would
	# talk to a system about to vanish. Non-fatal — a fast reboot can be over
	# before the first poll.
	just _wait-ssh "$target" down 180 || true

	# An encrypted host comes back into its initrd, not into its system: it now
	# listens on 2222 from the very first boot (the install staged the initrd
	# key), so the passphrase can be answered from here. No-op otherwise.
	just unlock "{{host}}" "$target"

	# NOT "$target": the installer and the installed system do not always land
	# on the same address. Take whichever one actually answers and carry it
	# through the rest of the chain.
	answer=$(just _wait-any "{{host}}" "$target" 22)
	read -r target port <<<"$answer"
	just _log "{{host}} is back at $target." "INSTALL"
	just configure {{host}} "$target"
	just _log "Let's do that automatically..."
	#just _fix_fs_permissions
	just _log "Adding and committing (amend)..." "GIT"

	# Amend only what `just install` itself committed. When it had nothing to
	# commit, HEAD is somebody else's work and amending would rewrite it in
	# silence, so fold the install leftovers into a commit of their own.
	msg="New host {{host}} dnf installation"
	git add .
	if git diff --cached --quiet ;then
		git reset
	elif [ "$(git log -1 --format=%s)" = "$msg" ] ;then
		git commit --amend --no-edit --allow-empty && git reset
	else
		git commit -m "$msg" && git reset
	fi
	just apply-verbose {{host}}
	just _log "Cleaning new system..."
	just gc {{host}}
	just _log "Last reboot..."
	sudo -i -u nix colmena exec --config "{{workDir}}/flake.nix" --on "{{host}}" "nohup bash -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &"

	# Without this an encrypted host ENDS the procedure sitting in its initrd,
	# waiting for a passphrase nobody is there to type — the whole point of a
	# remote install lost on the very last step. No-op on a clear host, and on
	# an encrypted one that came back on 22 on its own.
	just _wait-ssh "$target" down 180 || true
	just unlock "{{host}}" "$target"

	# The redirection was only meant to survive the install: from here the host
	# answers under its own name, at home or wherever it is next plugged in.
	just roaming-clear "{{host}}"
	just _done
	just _log "Don't forget to comment or remove disko config in etc/config.yaml."

# Record the fleet default password (hash only, sops). Configures no account:
# `just passwd <login>` is what opens a session with it.
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
	yq --inplace '."default-password-hash" = strenv(BCRYPT_HASH)' {{sopsSecretsFile}}
	sops -e -i {{sopsSecretsFile}}
	just _fix_fs_permissions
	just _log "Default password updated, apply it with 'just passwd <login>'" "SOPS"

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

# With the key plugged into this admin host (~3 touches), captures:
#   - the pam_u2f credential -> usr/secrets/yubikeys.json (public, committed):
#     a touch replaces the session password on every host of the user;
#   - a FIDO2 hmac-secret credential -> derived secret in sops: encrypted
#     hosts self-enroll their LUKS headers at next apply (no key needed there).
# Sets a FIDO2 PIN beforehand if the key has none: Kanidm passkeys require
# user verification (PAM and LUKS never request UV, they stay touch-only).
# Ensures the shared `luks-passphrase` sops secret exists (authorizes keyslot
# management on hosts), then prints the Kanidm passkey procedure (WebAuthn is
# an interactive web ceremony by design; Vaultwarden 2FA is self-service).
# `action=revoke` removes the (user, key) everywhere at next apply.
#
# Re-running is idempotent: the plugged key is identity-checked (silent FIDO2
# assertion against the registered credId). Same key = nothing to do; different
# key = full replacement, the old credential is pruned fleet-wide at next apply
# (old Kanidm/Vaultwarden passkeys must be removed by hand). Requires exactly
# ONE plugged key: with several, each capture could target a different device.
#
# YubiKey enrollment: ONE physical enrollment per (user, key), fleet-wide.
[group('install')]
yubikey user key='main' action='enroll':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just yubikey "{{user}}" "{{key}}" "{{action}}"
	registry={{secretsDir}}/yubikeys.json
	case "{{key}}" in main|backup) ;; *) just _fail "key must be 'main' or 'backup'" ;; esac
	yq -e '.users."{{user}}"' {{workDir}}/etc/config.yaml >/dev/null 2>&1 \
		|| just _fail "Unknown user '{{user}}' (see etc/config.yaml)."
	[ -f {{sopsSecretsFile}} ] || just _fail "No sops secrets file: run 'just configure-admin-host' first."
	just _sops_before_edit
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}

	# Revocation is declarative: dropping the registry entry + the sops secret
	# removes the PAM credential and prunes the LUKS keyslots at next apply.
	if [ "{{action}}" = "revoke" ] ;then
		[ -f "$registry" ] || just _fail "No registry ($registry)."
		yq -i -p=json -o=json 'del(."{{user}}"."{{key}}")' "$registry"
		yq -i -p=json -o=json 'del(."{{user}}" | select(length == 0))' "$registry"
		sops unset {{sopsSecretsFile}} '["yubikey"]["{{user}}"]["{{key}}"]' || true
		just _fix_fs_permissions
		just _log "Revoked {{user}}/{{key}}. Commit and 'just apply' to propagate." "YUBIKEY"
		exit 0
	fi
	[ "{{action}}" = "enroll" ] || just _fail "Unknown action '{{action}}' — valid: enroll, revoke"
	domain=$(yq -r '.network.domain' {{workDir}}/etc/config.yaml)
	origin="pam://$domain"

	# FIDO2 tools come from a transient nix shell (nothing to install first)
	# and run as root (direct hidraw access to the key).
	fido() { sudo {{nix}} shell nixpkgs#pam_u2f nixpkgs#libfido2 --command "$@" ; }

	# Exactly one plugged key: with several, pamu2fcfg and fido2-* each pick
	# their own device and can silently capture the wrong key.
	devs=$(fido fido2-token -L | cut -d: -f1)
	[ -n "$devs" ] || just _fail "No FIDO2 key detected: plug the '{{key}}' YubiKey of {{user}}."
	[ "$(printf '%s\n' "$devs" | wc -l)" = 1 ] \
		|| just _fail "Several FIDO2 keys detected: plug only the '{{key}}' YubiKey of {{user}}."
	dev=$devs

	# Physical identity check: a credId only asserts on the key that minted it
	# (up=false: silent, no touch nor PIN). Same key + intact sops secret =
	# idempotent no-op; a key already enrolled under the other name is refused;
	# any other mismatch (new or factory-reset key) = full replacement below.
	assert_ok() {
		printf '%s\n%s\n%s\n' "$(openssl rand -base64 32)" io.systemd.cryptsetup "$1" \
			| fido fido2-assert -G -t up=false "$dev" >/dev/null 2>&1
	}
	if [ -f "$registry" ] ;then
		for kname in main backup ;do
			cred=$(yq -r ".\"{{user}}\".\"$kname\".credId // \"\"" "$registry")
			[ -n "$cred" ] || continue
			if assert_ok "$cred" ;then
				[ "$kname" = "{{key}}" ] \
					|| just _fail "This physical key is already enrolled as {{user}}/$kname."
				if sops -d --extract '["yubikey"]["{{user}}"]["{{key}}"]["luks-secret"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
					just _fix_fs_permissions
					just _log "This key is already enrolled as {{user}}/{{key}}: nothing to do." "YUBIKEY"
					exit 0
				fi
				just _log "Registry entry intact but sops secret missing: re-enrolling." "YUBIKEY"
			elif [ "$kname" = "{{key}}" ] ;then
				just _warn "Different physical key: replacing {{user}}/{{key}} (old credential pruned at next apply; remove old Kanidm/Vaultwarden passkeys by hand)."
			fi
		done
	fi

	# Kanidm passkeys need WebAuthn user verification, which the key satisfies
	# with its FIDO2 PIN: create it if missing. Once set, the captures below
	# prompt for it (CTAP2 requires PIN auth to mint credentials).
	if fido fido2-token -I "$dev" | grep -q noclientPin ;then
		just _log "Kanidm (WebAuthn) requires a FIDO2 PIN and this key has none: set it now." "YUBIKEY"
		fido fido2-token -S "$dev"
	fi

	# Fixed origin/appid: one PAM credential is valid on the whole fleet.
	just _log "PAM credential: touch the key..." "YUBIKEY"
	pamline=$(fido pamu2fcfg -u "{{user}}" -o "$origin" -i "$origin")
	pamcred="${pamline#*:}"
	[ -n "$pamcred" ] || just _fail "pamu2fcfg failed."

	# LUKS: non-discoverable hmac-secret credential bound to the
	# systemd-cryptsetup relying party. The derived secret (HMAC of a fixed
	# salt) is only reproducible with the physical key; it goes to sops and
	# becomes the keyslot passphrase on every encrypted host of the user.
	just _log "LUKS credential: touch the key..." "YUBIKEY"
	cred=$(printf '%s\n%s\n%s\n%s\n' "$(openssl rand -base64 32)" io.systemd.cryptsetup "{{user}}" \
		"$(openssl rand -base64 16)" | fido fido2-cred -M -h "$dev")
	credid=$(printf '%s\n' "$cred" | sed -n 5p)
	salt=$(openssl rand -base64 32)
	just _log "LUKS secret derivation: touch the key..." "YUBIKEY"
	secret=$(printf '%s\n%s\n%s\n%s\n' "$(openssl rand -base64 32)" io.systemd.cryptsetup "$credid" "$salt" \
		| fido fido2-assert -G -h "$dev" | sed -n 5p)
	{ [ -n "$credid" ] && [ -n "$secret" ] ; } || just _fail "FIDO2 hmac-secret capture failed."

	# Shared LUKS install passphrase: asked once (only if missing from sops),
	# hosts use it to authorize new keyslots. Never displayed nor stored in clear.
	if ! sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
		echo -n "LUKS passphrase typed at hosts install (disko): "
		read -s LP ; echo
		[ -n "$LP" ] || just _fail "Empty passphrase."
		sops set {{sopsSecretsFile}} '["luks-passphrase"]' "\"$LP\""
	fi
	sops set {{sopsSecretsFile}} '["yubikey"]["{{user}}"]["{{key}}"]["luks-secret"]' "\"$secret\""

	# Public registry consumed by dnf/modules/system/yubikey.nix.
	[ -f "$registry" ] || echo '{}' > "$registry"
	PAM="$pamcred" CID="$credid" SALT="$salt" yq -i -p=json -o=json \
		'."{{user}}"."{{key}}" = {"pam": strenv(PAM), "credId": strenv(CID), "salt": strenv(SALT)}' "$registry"
	just _fix_fs_permissions
	just _log "Enrolled {{user}}/{{key}}." "YUBIKEY"
	just _log "Now: git add usr/secrets/yubikeys.json && just commit ... && just apply" "YUBIKEY"

	# Kanidm passkey: interactive web ceremony (once for the whole SSO). Mint
	# the reset link now if possible, else print the manual procedure.
	if [ "$(yq -r '.network.coordination.enable' {{workDir}}/etc/config.yaml)" = "true" ] ;then
		hcs=$(yq -r '.network.coordination.hostname' {{workDir}}/etc/config.yaml)
		just _log "Kanidm reset link for the passkey (idm_admin login):" "YUBIKEY"
		ssh -t nix@"$hcs" "kanidm person credential create-reset-token {{user}} --name idm_admin" \
			|| just _warn "Token not created — run: just enter $hcs ; kanidm person credential create-reset-token {{user}} --name idm_admin"
		just _info "Web ceremony: refuse the password-manager popup (Bitwarden/KeePassXC), the passkey must land on the physical key (FIDO2 PIN + touch)." "YUBIKEY"
	fi
	just _info "Vaultwarden: add the key in the web vault (Settings > Security > Two-step login, WebAuthn)." "YUBIKEY"

# LUKS provisioning: shared + per-host passphrase, remote unlock. Fully
# idempotent (safe from `just configure`); a host without a LUKS volume is a
# logged no-op. Actions:
#
# - `pre`   offline half, run by `just install` BEFORE the build: sops secrets
#           (shared `luks-passphrase`, per-host `luks/<host>/passphrase`, initrd
#           SSH host key `luks/<host>/initrd-key`) and the public manifest entry
#           in usr/secrets/luks.json. Never touches the target.
# - ``      `pre`, then converge the target: put the initrd host key back if it
#           is missing, record the gateway WAN IP so `just enter`/`just unlock`
#           still find the initrd sshd when the VPN is down, and bootstrap the
#           shared keyslot of a host installed before the shared-format era.
# - `passwd` rotate the per-host passphrase, then converge.
# - `show`  read-only audit: keyslot table + remote-unlock conformity.
#
# There is no install passphrase to retype: `just install` formats the volume
# with the shared one (nixos-anywhere --disk-encryption-keys), so the format
# keyslot IS the shared keyslot. See dnf/modules/system/luks.nix.
#
# LUKS provisioning: shared + per-host passphrase, remote unlock (idempotent)
[group('install')]
luks host action='' ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just luks "{{host}}" "{{action}}" "{{ip}}"
	case "{{action}}" in ''|pre|passwd|show) ;; *) just _fail "Unknown action '{{action}}' — valid: pre, passwd, show" ;; esac
	manifest={{secretsDir}}/luks.json
	hostconf=$(just _host_conf "{{host}}")
	[ -n "$hostconf" ] || just _fail "Unknown host '{{host}}' (see etc/config.yaml)."

	# No LUKS = no-op: keeps the recipe safely callable from `just configure`.
	if ! grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/disko.nix 2>/dev/null ;then
		just _log "No LUKS volume on {{host}}: nothing to do." "LUKS"
		exit 0
	fi
	[ -f {{sopsSecretsFile}} ] || just _fail "No sops secrets file: run 'just configure-admin-host' first."
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}

	#--------------------------------------------------------------------------
	# Offline phase (`pre`): everything that must exist before the build
	#--------------------------------------------------------------------------

	if [ "{{action}}" != "show" ] ;then
		just _sops_before_edit

		# Shared passphrase: asked once fleet-wide. It authorizes keyslot
		# management (same slot `just yubikey` uses) and is what disko formats
		# every encrypted volume with.
		if ! sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
			echo -n "Shared LUKS passphrase (unlocks every encrypted host): "
			read -s LP ; echo
			[ -n "$LP" ] || just _fail "Empty passphrase."
			sops set {{sopsSecretsFile}} '["luks-passphrase"]' "\"$LP\""
		fi

		# Per-host passphrase: the slot handed to the machine's own user, so
		# they can unlock their station without holding the fleet key. Created
		# once, rotated only on an explicit 'passwd'.
		#
		# NEVER asked at install time: an interactive stop is precisely what
		# breaks a remote install, and at format time nobody knows yet who will
		# use the machine — the answer was always "empty". A random value still
		# earns its slot (a spare that opens the volume, and the fallback of
		# `just unlock`); `just luks <host> passwd` gives it a chosen value the
		# day that becomes a question.
		if [ "{{action}}" = "passwd" ] ;then
			echo -n "New LUKS passphrase for {{host}} (empty = random): "
			read -s PP ; echo
			if [ -n "$PP" ]; then
				echo -n "Confirm: "
				read -s PP2 ; echo
				[ "$PP" = "$PP2" ] || just _fail "Passphrases do not match."
			else
				PP=$(openssl rand -base64 32)
				just _log "Random passphrase generated (kept in sops only)." "LUKS"
			fi
			sops set {{sopsSecretsFile}} '["luks"]["{{host}}"]["passphrase"]' "\"$PP\""
		elif ! sops -d --extract '["luks"]["{{host}}"]["passphrase"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
			sops set {{sopsSecretsFile}} '["luks"]["{{host}}"]["passphrase"]' \
				"\"$(openssl rand -base64 32)\""
			just _log "Per-host passphrase generated at random (set one with 'just luks {{host}} passwd')." "LUKS"
		else
			just _log "Per-host passphrase already in sops (rotate with 'just luks {{host}} passwd')." "LUKS"
		fi

		# Initrd SSH host key. Born here and kept in sops, so `just install` can
		# stage it under /mnt (--extra-files) and the FIRST boot already listens
		# on 2222 — a key generated on the target would always arrive after the
		# bootloader that had to embed it. base64: byte-exact round-trip through
		# sops and YAML.
		if ! sops -d --extract '["luks"]["{{host}}"]["initrd-key"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
			# /run itself is root-only; fall back to TMPDIR for the few seconds
			# the private key exists outside sops.
			rt="${XDG_RUNTIME_DIR:-}" ; [ -n "$rt" ] && [ -d "$rt" ] || rt=$(dirname "$(mktemp -u)")
			tmp=$(mktemp -d -p "$rt" dnf-luks-XXXXXX) ; chmod 700 "$tmp"
			trap 'rm -rf "$tmp"' EXIT
			ssh-keygen -t ed25519 -N "" -q -f "$tmp/key"
			sops set {{sopsSecretsFile}} '["luks"]["{{host}}"]["initrd-key"]' \
				"\"$(base64 -w0 < "$tmp/key")\""

			# `-y` and not the .pub file: same derived form the convergence
			# compares against, so a match is a match.
			sops set {{sopsSecretsFile}} '["luks"]["{{host}}"]["initrd-key-pub"]' \
				"\"$(ssh-keygen -y -f "$tmp/key")\""
			rm -rf "$tmp" ; trap - EXIT
			just _log "Initrd SSH host key generated and stored in sops." "LUKS"
		fi

		# Public manifest consumed by dnf/modules/system/luks.nix. Entry created
		# once; existing fields (recorded wan IP) are preserved.
		[ -f "$manifest" ] || echo '{}' > "$manifest"
		yq -e '."{{host}}"' "$manifest" >/dev/null 2>&1 \
			|| yq -i -p=json -o=json '."{{host}}" = {}' "$manifest"
		just _fix_fs_permissions
	fi
	[ "{{action}}" != "pre" ] || exit 0

	#--------------------------------------------------------------------------
	# Target phase: converge (or audit) the machine itself
	#--------------------------------------------------------------------------

	target=$(just _resolve "{{host}}" "{{ip}}")
	if ! ssh -o ConnectTimeout=5 nix@"$target" true 2>/dev/null ;then
		if [ "{{action}}" = "show" ] ;then
			just _fail "{{host}} unreachable at $target (waiting in initrd? see 'just unlock')."
		fi
		just _warn "{{host}} unreachable at $target: re-run 'just luks {{host}}' once it is up, BEFORE any apply."
		exit 0
	fi

	SHARED=$(sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}})
	PERHOST=$(sops -d --extract '["luks"]["{{host}}"]["passphrase"]' {{sopsSecretsFile}})

	# Trailing `exit 0`: a `for` loop reports its LAST iteration, so the probe
	# failed whenever the final by-partlabel entry was not LUKS — devs was
	# correct, but `set -e` killed the recipe on the assignment. An ssh or sudo
	# failure still surfaces: the snippet never runs in that case.
	devs=$(echo 'for p in /dev/disk/by-partlabel/*; do cryptsetup isLuks --type luks2 "$p" 2>/dev/null && echo "$p"; done; exit 0' \
		| ssh nix@"$target" sudo bash -s)
	[ -n "$devs" ] || just _fail "No LUKS2 volume found on {{host}} (disko config out of sync?)."

	# Prints the keyslot a passphrase unlocks, empty when it unlocks none.
	slot_of() {
		printf '%s' "$1" \
			| ssh nix@"$target" "sudo LC_ALL=C cryptsetup --verbose open --test-passphrase --key-file=- '$2'" 2>&1 \
			| sed -n 's/^Key slot \([0-9]\+\) unlocked.*/\1/p' | head -n1 || true
	}

	if [ "{{action}}" = "show" ] ;then
		just _luks-show "{{host}}" "$target"
		exit 0
	fi

	# A host provisioned before the key lived in sops already runs an initrd
	# built around ITS key: adopt that one rather than impose the freshly
	# generated backup, which would only break remote unlock until the next
	# bootloader install. Compared on the public halves, nothing sensitive
	# leaves the target.
	# Derived from the private key with `ssh-keygen -y`, not read from the .pub
	# file: only the private half is authoritative, and a stale or missing .pub
	# would send us adopting or restoring the wrong thing.
	targetpub=$(ssh nix@"$target" 'sudo ssh-keygen -y -f /var/lib/luks-initrd/ssh_host_ed25519_key 2>/dev/null' || true)
	sopspub=$(sops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' {{sopsSecretsFile}} 2>/dev/null || true)
	if [ -n "$targetpub" ] && [ "$targetpub" != "$sopspub" ] ;then
		just _log "Adopting the initrd host key already installed on {{host}}..." "LUKS"
		just _sops_before_edit
		sops set {{sopsSecretsFile}} '["luks"]["{{host}}"]["initrd-key"]' \
			"\"$(ssh nix@"$target" 'sudo base64 -w0 /var/lib/luks-initrd/ssh_host_ed25519_key')\""
		sops set {{sopsSecretsFile}} '["luks"]["{{host}}"]["initrd-key-pub"]' "\"$targetpub\""
		just _fix_fs_permissions
		ssh nix@"$target" 'sudo ssh-keygen -y -f /var/lib/luks-initrd/ssh_host_ed25519_key \
			| sudo tee /var/lib/luks-initrd/ssh_host_ed25519_key.pub >/dev/null'
	fi

	# The initrd host key must exist on the target when the bootloader embeds
	# it. Restored from sops, never regenerated here: a new key would silently
	# invalidate the one `just install` staged.
	if [ -z "$targetpub" ] ;then
		just _log "Restoring the initrd SSH host key from sops..." "LUKS"
		sops -d --extract '["luks"]["{{host}}"]["initrd-key"]' {{sopsSecretsFile}} \
			| ssh nix@"$target" 'sudo mkdir -p /var/lib/luks-initrd && sudo base64 -d > /var/lib/luks-initrd/ssh_host_ed25519_key'
		sops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' {{sopsSecretsFile}} \
			| ssh nix@"$target" 'sudo tee /var/lib/luks-initrd/ssh_host_ed25519_key.pub >/dev/null'
		ssh nix@"$target" 'sudo chown -R root:root /var/lib/luks-initrd \
			&& sudo chmod 700 /var/lib/luks-initrd \
			&& sudo chmod 600 /var/lib/luks-initrd/ssh_host_ed25519_key \
			&& sudo chmod 644 /var/lib/luks-initrd/ssh_host_ed25519_key.pub'
	fi

	# Gateways: record the current WAN IP. The VPN route to a zone dies with
	# its gateway, so `just enter` / `just unlock` fall back to this address to
	# reach the initrd sshd. Refreshed at each run (ISP renumbering needs a
	# re-run). The gateway hostname comes from var/generated/network.nix (same
	# source as the luks module): the raw config.yaml does not carry it, the
	# generator derives it from the host profiles.
	zone=$(echo "$hostconf" | yq -p=json -r '.zone // ""')
	zone="${zone%%:*}"
	wanif=$(yq -r ".zones.\"$zone\".gateway.wan.interface // \"\"" {{workDir}}/etc/config.yaml)
	gwhost=$({{nix}} eval --impure --raw \
		--expr "(import {{workDir}}/var/generated/network.nix).zones.\"$zone\".gateway.hostname or \"\"" 2>/dev/null || echo "")
	if [ -n "$wanif" ] && [ "$gwhost" = "{{host}}" ] ;then
		wan=$(ssh nix@"$target" "ip -4 -o addr show dev '$wanif' scope global" 2>/dev/null \
			| awk '{print $4}' | cut -d/ -f1 | head -1)
		if [ -n "$wan" ] ;then
			# The earlier _fix_fs_permissions restored usr/secrets/ ownership:
			# reopen it for the manifest write, restore right after.
			just _sops_before_edit
			WAN="$wan" yq -i -p=json -o=json '."{{host}}".wan = strenv(WAN)' "$manifest"
			just _fix_fs_permissions
			just _log "WAN IP of {{host}} recorded: $wan" "LUKS"
		fi
	fi

	# Legacy bootstrap. A volume formatted before the shared-passphrase era
	# accepts neither managed passphrase, and the sync/enroll units cannot
	# authorize anything without one: add the shared slot here, with the
	# passphrase that was typed at that install. Never happens on a host
	# installed by the current `just install`.
	fixed=""
	for dev in $devs ;do
		if [ -n "$(slot_of "$SHARED" "$dev")" ] || [ -n "$(slot_of "$PERHOST" "$dev")" ] ;then
			just _log "$dev already accepts a managed passphrase." "LUKS"
			continue
		fi
		just _warn "$dev accepts no managed passphrase: host installed before the shared format."
		if [ -z "${INSTALL:-}" ] ;then
			echo -n "Legacy install passphrase of {{host}}: "
			read -s INSTALL ; echo
			[ -n "$INSTALL" ] || just _fail "Empty passphrase."
		fi

		# Old key on stdin, new key via a root-only tmpfs file, both wiped.
		printf '%s\n%s\n' "$INSTALL" "$SHARED" | ssh nix@"$target" "sudo bash -c 'IFS= read -r cur; IFS= read -r new; t=\$(mktemp -p /run); chmod 600 \"\$t\"; printf %s \"\$new\" >\"\$t\"; rc=0; printf %s \"\$cur\" | cryptsetup luksAddKey --key-file=- $dev \"\$t\" >/dev/null 2>&1 || rc=1; rm -f \"\$t\"; exit \$rc'" \
			|| just _fail "luksAddKey failed on $dev (wrong install passphrase?)."
		just _log "Shared keyslot bootstrapped on $dev." "LUKS"
		fixed=1
	done

	# A bootstrap unlocks the sync/enroll units: re-run them now so the
	# per-host slot and the FIDO2 tokens land without waiting for a reboot.
	if [ -n "$fixed" ] ;then
		ssh nix@"$target" 'sudo systemctl restart luks-passphrase-sync.service yubikey-luks-enroll.service' \
			|| just _warn "Sync units not deployed yet: run 'just apply {{host}}' to converge."
	fi
	just _log "Provisioned {{host}}. Audit it with 'just luks {{host}} show'." "LUKS"
	just _log "If luks.json changed: git add usr/secrets/luks.json && just commit ... && just apply {{host}}" "LUKS"

# Implementation of `just luks <host> show`: keyslot table + remote-unlock audit.
#
# Live verification wherever it is possible — every managed passphrase is
# actually tested against the header, so the table shows what the volume accepts
# today, not what a ledger remembers. Exits non-zero when a check fails, so the
# recipe can be dropped into a script.
#
# Column widths are computed, never hard-coded: a device path or a YubiKey name
# is as long as it happens to be.
_luks-show host target:
	#!/usr/bin/env bash
	set -euo pipefail
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}
	shared=$(sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}})
	perhost=$(sops -d --extract '["luks"]["{{host}}"]["passphrase"]' {{sopsSecretsFile}})
	failures=0
	pass() { printf '  {{GREEN}}OK{{NORMAL}}    %s\n' "$1" ; }
	fail() { printf '  {{RED}}FAIL{{NORMAL}}  %s\n' "$1" ; failures=$((failures + 1)) ; }
	warn() { printf '  {{YELLOW}}WARN{{NORMAL}}  %s\n' "$1" ; }

	# Token and registry may spell the same credential in either base64 flavour
	# (standard or url-safe, padded or not): fold both to one form to compare.
	b64norm() { tr '+/' '-_' | tr -d '=' ; }
	declare -A credname=()
	if [ -f {{secretsDir}}/yubikeys.json ] ;then
		while IFS=$'\t' read -r label cred ;do
			[ -n "$cred" ] || continue
			credname["$(printf %s "$cred" | b64norm)"]=$label
		done < <(yq -p=json -o=tsv '
			to_entries | .[] as $u | $u.value | to_entries | .[]
			| [$u.key + "/" + .key, .value.credId // ""]' {{secretsDir}}/yubikeys.json)
	fi

	devs=$(echo 'for p in /dev/disk/by-partlabel/*; do cryptsetup isLuks --type luks2 "$p" 2>/dev/null && echo "$p"; done; exit 0' \
		| ssh nix@"{{target}}" sudo bash -s)
	[ -n "$devs" ] || just _fail "No LUKS2 volume found on {{host}}."
	ledger=$(ssh nix@"{{target}}" 'sudo cat /var/lib/luks-passphrase/ledger 2>/dev/null || true')

	echo
	printf '{{BOLD}}LUKS — {{host}} ({{target}}){{NORMAL}}\n'
	for dev in $devs ;do
		meta=$(ssh nix@"{{target}}" "sudo cryptsetup luksDump --dump-json-metadata '$dev'")
		slot_of() {
			printf '%s' "$1" \
				| ssh nix@"{{target}}" "sudo LC_ALL=C cryptsetup --verbose open --test-passphrase --key-file=- '$dev'" 2>&1 \
				| sed -n 's/^Key slot \([0-9]\+\) unlocked.*/\1/p' | head -n1 || true
		}
		sharedslot=$(slot_of "$shared")
		hostslot=$(slot_of "$perhost")

		# slot -> "content|source" for every slot we can name.
		declare -A content=() origin=()
		[ -z "$sharedslot" ] || { content[$sharedslot]="Shared passphrase" ; origin[$sharedslot]="sops luks-passphrase" ; }
		[ -z "$hostslot" ] || { content[$hostslot]="Host passphrase" ; origin[$hostslot]="sops luks/{{host}}/passphrase" ; }
		while IFS=$'\t' read -r ttype cred tslots ;do
			[ "$ttype" = "systemd-fido2" ] || continue
			label=${credname[$(printf %s "$cred" | b64norm)]:-unregistered}
			for s in ${tslots//,/ } ;do
				content[$s]="YubiKey $label"
				origin[$s]="systemd-fido2 token"
			done
		done < <(printf '%s' "$meta" | yq -p=json -o=tsv '
			.tokens // {} | to_entries | .[]
			| [.value.type, .value."fido2-credential" // "", (.value.keyslots // [] | join(","))]')

		mapfile -t slots < <(printf '%s' "$meta" | yq -p=json -o=tsv '.keyslots | keys | .[]' | sort -n)
		w1=7 ; w2=0 ; w3=0
		for s in "${slots[@]}" ;do
			c=${content[$s]:-Unknown} ; o=${origin[$s]:--}
			[ ${#c} -le $w2 ] || w2=${#c}
			[ ${#o} -le $w3 ] || w3=${#o}
		done
		[ $w2 -ge 7 ] || w2=7
		[ $w3 -ge 6 ] || w3=6
		echo
		printf '{{BOLD}}%s{{NORMAL}}\n' "$dev"
		printf "  %-4s  %-${w2}s  %-${w3}s  %s\n" "Slot" "Content" "Source" "Check"
		printf "  %-4s  %-${w2}s  %-${w3}s  %s\n" "----" "$(printf '%*s' "$w2" '' | tr ' ' '-')" "$(printf '%*s' "$w3" '' | tr ' ' '-')" "-----------------"
		for s in "${slots[@]}" ;do
			c=${content[$s]:-Unknown} ; o=${origin[$s]:--} ; check="unverifiable"
			case "$c" in
				"Shared passphrase"|"Host passphrase") check="opens the volume" ;;
				"YubiKey unregistered") check="not in yubikeys.json" ;;
				YubiKey*) check="enrolled" ;;
				Unknown) check="not managed by DNF" ;;
			esac
			printf "  %-4s  %-${w2}s  %-${w3}s  %s\n" "$s" "$c" "$o" "$check"
		done
		printf '  Slots in use: %s/32\n' "${#slots[@]}"

		# A managed passphrase that opens nothing is the one failure that locks
		# the fleet out of the machine.
		[ -n "$sharedslot" ] || fail "$dev: the shared passphrase does not open this volume"
		[ -n "$hostslot" ] || fail "$dev: the per-host passphrase does not open this volume (apply the host?)"

		# The ledger drives rotation: a stale entry silently kills the wrong
		# slot at the next passphrase change.
		for entry in "shared:$sharedslot" "host:$hostslot" ;do
			label=${entry%%:*} ; live=${entry#*:}
			[ -n "$live" ] || continue
			recorded=$(printf '%s\n' "$ledger" | awk -v l="$label" -v d="$dev" '$1 == l && $2 == d {print $4}' | tail -n1)
			[ -n "$recorded" ] || { warn "$dev: $label slot $live is not in the ledger yet (apply the host)" ; continue ; }
			[ "$recorded" = "$live" ] && continue
			fail "$dev: ledger says $label is slot $recorded, the volume answers on $live"
		done
	done

	#--------------------------------------------------------------------------
	# Remote unlock conformity
	#--------------------------------------------------------------------------

	echo
	printf '{{BOLD}}Remote unlock{{NORMAL}}\n'
	yq -e '."{{host}}"' {{secretsDir}}/luks.json >/dev/null 2>&1 \
		&& pass "declared in usr/secrets/luks.json" \
		|| fail "missing from usr/secrets/luks.json (the module stays inert)"

	fp=$(ssh nix@"{{target}}" 'sudo ssh-keygen -lf /var/lib/luks-initrd/ssh_host_ed25519_key 2>/dev/null || true' | awk '{print $2}')
	if [ -n "$fp" ] ;then
		pass "initrd host key present on the target ($fp)"

		# The public half is enough to compare, and never lands on a disk.
		backup=$(sops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' {{sopsSecretsFile}} 2>/dev/null \
			| ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}' || true)
		if [ -z "$backup" ] ;then
			fail "no initrd key backup in sops: a reinstall would lose remote unlock"
		elif [ "$backup" = "$fp" ] ;then
			pass "sops backup matches the key on the target"
		else
			fail "sops backup ($backup) differs from the target key ($fp)"
		fi
	else
		fail "no initrd host key on the target: the next apply builds a bootloader without remote unlock"
	fi

	# No --raw here: it only accepts strings and would error out on a bool/int.
	enabled=$({{nix}} eval {{workDir}}#nixosConfigurations."{{host}}".config.boot.initrd.network.ssh.enable 2>/dev/null || echo "")
	port=$({{nix}} eval {{workDir}}#nixosConfigurations."{{host}}".config.boot.initrd.network.ssh.port 2>/dev/null || echo "")
	[ "$enabled" = "true" ] \
		&& pass "the built configuration enables initrd sshd on port $port" \
		|| fail "the built configuration has no initrd sshd (missing nix.pub, or host not in luks.json)"

	# The failure mode this whole design exists for: initrd secrets are appended
	# when the bootloader is installed, so a key created after the last
	# generation is simply not in the initrd that boots.
	# `|| echo 0` on a pipeline reports the LAST command, so an empty `find`
	# still exits 0 and yields an empty string: default afterwards, not inside.
	keyage=$(ssh nix@"{{target}}" 'sudo stat -c %Y /var/lib/luks-initrd/ssh_host_ed25519_key 2>/dev/null' || true)
	bootage=$(ssh nix@"{{target}}" 'sudo find /boot -type f \( -name "*.efi" -o -name "initrd*" \) -printf "%T@\n" 2>/dev/null | cut -d. -f1 | sort -n | tail -1' || true)
	keyage=${keyage:-0} ; bootage=${bootage:-0}
	if [ "$keyage" -gt 0 ] && [ "$bootage" -gt 0 ] && [ "$keyage" -le "$bootage" ] ;then
		pass "the installed bootloader is newer than the initrd key"
	elif [ "$keyage" -gt 0 ] && [ "$bootage" -gt 0 ] ;then
		fail "the initrd key is newer than the bootloader: run 'just apply {{host}}' before rebooting"
	else
		warn "could not compare the initrd key and bootloader dates"
	fi

	built=$({{nix}} eval --raw {{workDir}}#nixosConfigurations."{{host}}".config.system.build.toplevel 2>/dev/null || echo "")
	running=$(ssh nix@"{{target}}" 'readlink -f /run/current-system' 2>/dev/null || echo "")
	if [ -n "$built" ] && [ "$built" = "$running" ] ;then
		pass "the running system is the configuration audited above"
	else
		warn "the running system predates the current configuration (apply pending)"
	fi

	zone=$(just _host_conf "{{host}}" | yq -p=json -r '.zone // ""')
	gwhost=$({{nix}} eval --impure --raw \
		--expr "(import {{workDir}}/var/generated/network.nix).zones.\"${zone%%:*}\".gateway.hostname or \"\"" 2>/dev/null || echo "")
	if [ "$gwhost" = "{{host}}" ] ;then
		wan=$(yq -r '."{{host}}".wan // ""' {{secretsDir}}/luks.json)
		[ -n "$wan" ] \
			&& pass "gateway WAN address recorded ($wan)" \
			|| fail "no WAN address recorded: unreachable in initrd once the VPN is down"
	fi

	echo
	[ "$failures" -eq 0 ] || just _fail "$failures check(s) failed on {{host}}."
	just _log "{{host}} is conform." "LUKS"

# Edit sops secrets
[group('install')]
sops:
	#!/usr/bin/env bash
	set -euo pipefail
	just _sops_before_edit
	sudo -i -u nix EDITOR=vim sops {{sopsSecretsFile}} || true
	just _fix_fs_permissions

# Provision the Matrix alert bot + rooms (idempotent) from network.matrix.
# Reads config.yaml (network.matrix.{admin,bot}), creates/refreshes the bot,
# webhook secret and the warnings/incidents rooms, and writes the resulting
# room IDs back into config.yaml. Re-run any time; it only fixes what's missing.
#
# Provision the Matrix alert bot and its rooms (idempotent)
[group('install')]
configure-alert-bot:
	#!/usr/bin/env bash
	set -euo pipefail
	WORKDIR="{{workDir}}" bash {{assetsDir}}/scripts/just-configure-alert-bot.sh
	just _fix_fs_permissions

# Replication is automatic when idm runs on the HCS and >=1 zone gateway. Bootstrap
# is a two-step deploy:
#   1. `just apply` once  -> each replication node generates its identity.
#   2. `just idm-sync-certs` -> collect the public certs into usr/secrets.
#   3. commit + `just apply` again -> partner blocks appear, replication starts.
# Re-run any time a replica is added. Certs are public; safe to commit.
#
# Runs as the current (admin) user so the collected files stay user-owned and
# committable. Only the per-node SSH needs the `nix` deploy identity (its keys,
# config and known_hosts live in ~nix/.ssh), so just that call uses `sudo -u nix`.
#
# Sync Kanidm replication certificates (multi-zone read-only replicas).
[group('install')]
idm-sync-certs:
	#!/usr/bin/env bash
	set -euo pipefail
	dest="{{secretsDir}}/replication"
	mkdir -p "$dest"

	# TODO: itérer uniquement sur HCS et gateways... un peu long d'aller chercher sur 150 noeuds.
	nodes=$(just _hive-nodes)
	[ -n "$nodes" ] || just _fail "No hive nodes found (colmena eval failed?)."
	found=0
	for node in $nodes ;do

		# show-replication-certificate only succeeds on a node that has a
		# [replication] block; other hosts fail and are skipped. The cert body
		# is the bare DER (MII...) that goes verbatim into supplier/consumer.
		# Kanidm emits it in base64url (URL-safe `-`/`_`), so the class must
		# accept both alphabets — otherwise the cert is truncated at the first
		# `-`/`_`. `-H` gives ssh the nix user's HOME so it uses ~nix/.ssh.
		cert=$(sudo -u nix -H ssh -o BatchMode=yes nix@"$node" \
			'sudo kanidmd show-replication-certificate -c /etc/kanidm/server.toml 2>/dev/null | grep -oE "MII[A-Za-z0-9+/=_-]+" | head -n1' \
			2>/dev/null || true)
		if [ -n "$cert" ] ;then
			echo "$cert" > "$dest/${node}.pem"
			just _info "Synced replication cert for ${node}." "IDM"
			found=$((found+1))
		else
			just _info "No replication cert on ${node} (skipped)." "IDM"
		fi
	done
	[ "$found" -gt 0 ] || just _warn "No replication certificates collected — did you 'just apply' first?"
	just _log "Done. Commit usr/secrets/replication/ then 'just apply' again to activate replication." "IDM"

# Read-only "doctor": never wipes, restarts or applies anything. Pass the supplier
# (the HCS / coordination host) and the comma-separated consumer gateways, e.g.
#   just idm-fix-replica hcs agate,gw
# The usual blocker is dangling references in the supplier database that make the
# replication refresh fail (post_repl_refresh referential-integrity check). This
# checks supplier integrity, certificate sync and each consumer's last refresh,
# then prints a copy-pasteable checklist. Same SSH/identity conventions as
# idm-sync-certs (only the per-node SSH uses the nix deploy user).
#
# Diagnose Kanidm replication health and prescribe the exact remediation steps.
[group('install')]
idm-fix-replica supplier consumers:
	#!/usr/bin/env bash
	set -euo pipefail
	dest="{{secretsDir}}/replication"
	supplier="{{supplier}}"
	IFS=',' read -ra consumers <<< "{{consumers}}"
	ok=1
	refint_fail=0

	# Live replication certificate of a node (empty if it has no [replication]).
	repl_cert() {
		sudo -u nix -H ssh -o BatchMode=yes nix@"$1" \
			'sudo kanidmd show-replication-certificate -c /etc/kanidm/server.toml 2>/dev/null | grep -oE "MII[A-Za-z0-9+/=_-]+" | head -n1' \
			2>/dev/null || true
	}

	# Synced .pem for a node (single line, whitespace stripped), empty if absent.
	synced_cert() { [ -f "$dest/$1.pem" ] && tr -d '\n\r ' < "$dest/$1.pem" || true; }

	# Remote command as the nix deploy user; never abort the recipe on failure.
	on() { sudo -u nix -H ssh -o BatchMode=yes nix@"$1" "$2" 2>/dev/null || true; }

	just _log "Diagnostic de la réplication Kanidm (supplier=$supplier)" "IDM"

	# Local: every cert must exist AND be git-tracked, else the flake eval ignores it.
	for n in "$supplier" "${consumers[@]}" ;do
		if [ ! -f "$dest/$n.pem" ] ;then
			just _warn "Cert $n.pem absent (sync manquante)." ; ok=0
		elif ! git -C {{workDir}} ls-files --error-unmatch "$dest/$n.pem" >/dev/null 2>&1 ;then
			just _warn "Cert $n.pem NON suivi par git → invisible au flake ('git add' requis)." ; ok=0
		fi
	done

	# Supplier: service up, cert in sync, database referential integrity.
	just _log "Supplier $supplier" "IDM"
	act=$(on "$supplier" 'systemctl is-active kanidm')
	just _info "kanidm: ${act:-injoignable}" "IDM"
	[ "$act" = "active" ] || ok=0
	live=$(repl_cert "$supplier") ; sync=$(synced_cert "$supplier")
	if [ -z "$live" ] ;then
		just _warn "Pas de cert de réplication live sur $supplier." ; ok=0
	elif [ "$live" != "$sync" ] ;then
		just _warn "Cert HCS live ≠ cert synchronisé → consumers en UnknownCA (re-sync requise)." ; ok=0
	else
		just _info "Cert de réplication en phase." "IDM"
	fi
	verify=$(on "$supplier" 'sudo kanidmd database verify -c /etc/kanidm/server.toml 2>&1')
	if printf '%s' "$verify" | grep -qE 'RefintNotUpheld|Err\(' ;then
		just _err "Intégrité base HCS: ÉCHEC (références pendantes) :"
		printf '%s\n' "$verify" | grep -E 'RefintNotUpheld|Err\(' | sed 's/^/      /'
		refint_fail=1 ; ok=0
	else
		just _info "Intégrité base HCS: OK." "IDM"
	fi

	# Consumers: service up, role, supplier_cert freshness, last refresh outcome.
	for c in "${consumers[@]}" ;do
		just _log "Consumer $c" "IDM"
		act=$(on "$c" 'systemctl is-active kanidm')
		role=$(on "$c" "grep -oE '^role[[:space:]]*=.*' /etc/kanidm/server.toml")
		just _info "kanidm: ${act:-injoignable} | ${role:-role inconnu}" "IDM"
		[ "$act" = "active" ] || ok=0
		conf=$(on "$c" "grep -oE 'MII[A-Za-z0-9+/=_-]+' /etc/kanidm/server.toml | head -n1")
		if [ -n "$sync" ] && [ -n "$conf" ] && [ "$conf" != "$sync" ] ;then
			just _warn "supplier_cert de $c périmé (≠ cert HCS courant) → UnknownCA." ; ok=0
		fi
		jr=$(on "$c" 'journalctl -u kanidm --since -10min --no-pager')
		if printf '%s' "$jr" | grep -q 'ReferentialIntegrity' ;then
			just _warn "Dernier refresh: ÉCHEC intégrité référentielle (corruption supplier)." ; ok=0
		elif printf '%s' "$jr" | grep -q 'UnknownCA' ;then
			just _warn "Dernier refresh: ÉCHEC UnknownCA (cert périmé)." ; ok=0
		elif printf '%s' "$jr" | grep -qE 'consumer_apply_refresh|Reindexed' ;then
			just _info "Dernier refresh: OK." "IDM"
		else
			just _info "Dernier refresh: aucun récent." "IDM"
		fi
	done

	# Verdict + prescription (printed only; nothing is executed).
	if [ "$ok" = 1 ] ;then
		just _log "Réplication saine — rien à faire. ✅" "IDM"
		exit 0
	fi
	just _warn "Réplication NON saine — prescription ci-dessous :"
	echo
	if [ "$refint_fail" = 1 ] ;then
		echo "  [HCS] Base corrompue (RefintNotUpheld) : le refresh échouera tant"
		echo "  qu'elle n'est pas réparée. kanidm n'a pas de 'repair refint'."
		echo "  Remède : RESTAURER la base HCS depuis une sauvegarde SAINE (antérieure"
		echo "  à la corruption — une sauvegarde récente peut être déjà corrompue),"
		echo "  puis resynchroniser le cert (la restauration peut le changer) :"
		echo
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo systemctl stop kanidm'"
		echo "    #  ... restaure /var/lib/kanidm/kanidm.db depuis ta sauvegarde ..."
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo systemctl start kanidm'"
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo kanidmd database verify -c /etc/kanidm/server.toml'  # doit être OK"
		echo "    just idm-sync-certs"
		echo "    git add usr/secrets/replication && git commit -m 'fix(idm): resync replication certs'"
		echo "    just apply $supplier,{{consumers}}"
		echo "    # forcer le 1er refresh sur un consumer si besoin :"
		echo "    sudo -u nix -H ssh nix@<consumer> 'sudo kanidmd refresh-replication-consumer -c /etc/kanidm/server.toml'"
	else
		echo "  Certs désynchronisés. Resynchronise et redéploie :"
		echo
		echo "    just idm-sync-certs"
		echo "    git add usr/secrets/replication && git commit -m 'fix(idm): resync replication certs'"
		echo "    just apply $supplier,{{consumers}}"
	fi
	echo

#==============================================================================
# Rotation
#==============================================================================
#
# Infra age key rotation, in three explicit, integrity-checked steps:
#   1. just rotate init       generate a new key, keep the old one as a second
#                             recipient, re-encrypt secrets to both.
#   2. just rotate push-keys  push the combined (new+old) key to every hive
#                             host, so each one decrypts whatever its store
#                             holds, in any apply/push order.
#   3. just rotate finalize   once every host carries the new key (verified
#                             first), drop the old one, re-encrypt to the new
#                             key only and push the new-only key everywhere.
#
# The presence of /etc/sops/age/infra.key.old marks a rotation in progress.

# (Re)generate usr/secrets/.sops.yaml from the current recipients: the admin
# SSH-derived age key plus the infra key(s). During a rotation both the new
# (.cur) and previous (.old) infra keys are recipients; otherwise just the
# single operational infra key.
_regen-sops-yaml:
	#!/usr/bin/env bash
	set -euo pipefail

	# Admin recipient, derived straight from the SSH public key (ssh-to-age on
	# the pub key yields a single age1... line, without parsing keys.txt which
	# some ssh-to-age versions don't expose as a native AGE-SECRET-KEY-1).
	ADM_PUB=$(ssh-to-age -i "$HOME/.ssh/id_ed25519.pub")
	recipients=("$ADM_PUB")

	# Infra recipients. age-keygen -y is only ever run on single-identity files.
	if [ -f {{sopsInfraCurKeyFile}} ] && [ -f {{sopsInfraOldKeyFile}} ] ;then
		recipients+=("$(age-keygen -y {{sopsInfraCurKeyFile}})")
		recipients+=("$(age-keygen -y {{sopsInfraOldKeyFile}})")
	else
		recipients+=("$(age-keygen -y {{sopsInfraKeyFile}})")
	fi
	just _sops_before_edit
	{
		echo "creation_rules:"
		echo "  - path_regex: \"[^/]+\\\\.yaml\$\""
		echo "    key_groups:"
		echo "    - age:"
		for r in "${recipients[@]}" ;do
			echo "      - ${r}"
		done
	} > {{sopsYamlFile}}

# List all colmena hive node names (the deploy source of truth), one per line.
_hive-nodes:
	#!/usr/bin/env bash
	set -euo pipefail
	colmena eval --config {{workDir}}/flake.nix -E '{ nodes, ... }: builtins.attrNames nodes' 2>/dev/null \
		| grep -oE '"[^"]+"' | tr -d '"'

# Rotate the infra age key (step: init | push-keys | finalize)
[group('install')]
rotate step:
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just rotate "{{step}}"
	case "{{step}}" in
		init)      just _rotate-infra-init ;;
		push-keys) just _rotate-infra-push-keys ;;
		finalize)  just _rotate-infra-finalize ;;
		*) just _fail "Unknown rotate step '{{step}}' — valid: init, push-keys, finalize" ;;
	esac

# Rotation step 1: introduce a new infra key alongside the old one.
_rotate-infra-init:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	if [ -f {{sopsInfraOldKeyFile}} ] || [ -f {{sopsInfraCurKeyFile}} ] ;then
		just _err "A rotation is already in progress."
		just _fail "Run 'just rotate push-keys' then 'just rotate finalize' (or remove {{sopsInfraCurKeyFile}} / {{sopsInfraOldKeyFile}} to abort)."
	fi
	if [ ! -s {{sopsAdminKeyFile}} ] ;then
		just _fail "Admin age key not found ({{sopsAdminKeyFile}}). Run 'just configure-admin-host' first."
	fi
	if [ ! -f {{sopsSecretsFile}} ] ;then
		just _fail "Secrets file not found ({{sopsSecretsFile}})."
	fi
	just _log "Generating a new infra key (keeping the old one as recipient)..." "ROTATE"

	# Make sure the key store is writable by the nix deploy user.
	sudo mkdir -p {{sopsInfraTargetDir}}
	sudo chown nix {{sopsInfraTargetDir}}

	# Preserve the current single key as .old, generate the new single key as
	# .cur, then make the operational infra.key the concatenation new+old: any
	# host that receives it decrypts secrets sealed for either identity.
	cp {{sopsInfraKeyFile}} {{sopsInfraOldKeyFile}}
	age-keygen -o {{sopsInfraCurKeyFile}}
	cat {{sopsInfraCurKeyFile}} {{sopsInfraOldKeyFile}} > {{sopsInfraKeyFile}}
	chmod 600 {{sopsInfraCurKeyFile}} {{sopsInfraOldKeyFile}} {{sopsInfraKeyFile}}

	# Re-encrypt secrets to admin + new + old, decrypting with the stable admin
	# key. sops resolves .sops.yaml from the CWD, so run it from the secrets dir
	# (same pattern as passwd-default), in a subshell to keep the recipe CWD.
	just _regen-sops-yaml
	just _log "Re-encrypting secrets for new + old recipients..." "ROTATE"
	( cd {{secretsDir}} && SOPS_AGE_KEY_FILE={{sopsAdminKeyFile}} sops updatekeys -y {{sopsSecretsFile}} )
	just _fix_fs_permissions
	just _log "Init done. Commit, deploy ('just apply ...'), then 'just rotate push-keys'." "ROTATE"

# Rotation step 2: push the combined key to every hive host.
_rotate-infra-push-keys:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	if [ ! -f {{sopsInfraOldKeyFile}} ] ;then
		just _fail "No rotation in progress. Run 'just rotate init' first."
	fi
	self=$(hostname)

	# Fail safe: an empty list means colmena eval failed — never report success
	# (or, in finalize, prune the old key) against zero hosts.
	nodes=$(just _hive-nodes)
	[ -n "$nodes" ] || just _fail "No hive nodes found (colmena eval failed?). Aborting."
	just _log "Pushing combined infra key to all hive hosts..." "ROTATE"
	failed=()
	for node in $nodes ;do

		# The admin host already holds the combined key locally; never scp to
		# self (push-key would chown the key to root and lock the tooling out).
		if [ "$node" = "$self" ] ;then
			just _info "Skipping admin host $node (already up to date)." "ROTATE"
			continue
		fi
		if just push-key "$node" ;then
			just _info "Pushed to $node." "ROTATE"
		else
			just _warn "Push FAILED for $node."
			failed+=("$node")
		fi
	done
	if [ ${#failed[@]} -ne 0 ] ;then
		just _fail "Key not delivered to: ${failed[*]} — fix connectivity and re-run 'just rotate push-keys'."
	fi
	just _log "All hosts have the combined key. After 'just apply' everywhere, run 'just rotate finalize'." "ROTATE"

# Rotation step 3: verify every host carries the new key, then drop the old one.
_rotate-infra-finalize:
	#!/usr/bin/env bash
	set -euo pipefail
	just _check_infra_admin
	if [ ! -f {{sopsInfraOldKeyFile}} ] || [ ! -f {{sopsInfraCurKeyFile}} ] ;then
		just _fail "No rotation in progress (nothing to finalize). Run 'just rotate init' first."
	fi
	if [ ! -s {{sopsAdminKeyFile}} ] ;then
		just _fail "Admin age key not found ({{sopsAdminKeyFile}})."
	fi
	self=$(hostname)
	NEW_PUB=$(age-keygen -y {{sopsInfraCurKeyFile}})

	# Fail safe: empty list => colmena eval failed; never prune against zero hosts.
	nodes=$(just _hive-nodes)
	[ -n "$nodes" ] || just _fail "No hive nodes found (colmena eval failed?). Aborting."

	# Integrity gate: refuse to drop the old key until EVERY hive host carries
	# the new one (else a host would be left unable to decrypt). Unreachable
	# hosts count as missing.
	just _log "Verifying every host carries the new key..." "ROTATE"
	missing=()
	for node in $nodes ;do
		[ "$node" = "$self" ] && continue
		tmp=$(mktemp)
		if ssh -o BatchMode=yes nix@"$node" 'sudo cat {{sopsInfraKeyFile}}' > "$tmp" 2>/dev/null \
			&& age-keygen -y "$tmp" 2>/dev/null | grep -qxF "$NEW_PUB" ;then
			just _info "$node OK." "ROTATE"
		else
			just _warn "$node is missing the new key (or unreachable)."
			missing+=("$node")
		fi
		rm -f "$tmp"
	done
	if [ ${#missing[@]} -ne 0 ] ;then
		just _fail "Cannot finalize — these hosts lack the new key: ${missing[*]}. Run 'just rotate push-keys' (and 'just apply') first."
	fi
	just _log "All hosts verified. Dropping the old key..." "ROTATE"

	# Operational key becomes the new single identity; remove the sidecars.
	mv {{sopsInfraCurKeyFile}} {{sopsInfraKeyFile}}
	rm -f {{sopsInfraOldKeyFile}}
	chmod 600 {{sopsInfraKeyFile}}

	# Re-encrypt secrets to admin + new only (the old key becomes useless).
	# Run sops from the secrets dir (CWD-based .sops.yaml discovery).
	just _regen-sops-yaml
	just _log "Re-encrypting secrets for the new key only..." "ROTATE"
	( cd {{secretsDir}} && SOPS_AGE_KEY_FILE={{sopsAdminKeyFile}} sops updatekeys -y {{sopsSecretsFile}} )
	just _fix_fs_permissions

	# Replace the combined key with the new-only key on every host. Hosts we
	# can't reach keep the combined key, so they keep working until re-pushed.
	just _log "Pushing new-only key to all hive hosts..." "ROTATE"
	failed=()
	for node in $nodes ;do
		[ "$node" = "$self" ] && continue
		if just push-key "$node" ;then :; else failed+=("$node"); fi
	done
	if [ ${#failed[@]} -ne 0 ] ;then
		just _warn "New-only key not pushed to: ${failed[*]} — re-run 'just push-key <host>' for them."
	fi
	just _log "Finalize done. Commit and 'just apply' everywhere to flush the old recipient." "ROTATE"

#==============================================================================
# Apply (colmena)
#==============================================================================
#
# Central build by default (see `buildOnTarget`): the deployer builds every
# closure once and harmonia shares it across the fleet. Set `buildOnTarget=1`
# to restore per-target builds. Ref: https://nixos.wiki/wiki/Binary_Cache

# Apply configuration using colmena
[group('apply')]
apply on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying nix configuration on {{on}} ({{what}})..."

	# Per-target build only when buildOnTarget is set; central build otherwise.
	bot=""; [ -n "{{buildOnTarget}}" ] && bot="--build-on-target"
	if [ "${USER:-}" = "nix" ] ;then
		colmena apply ${bot} --on "{{on}}" {{what}}
	else
		sudo -i -u nix colmena apply --config "{{workDir}}/flake.nix" ${bot} --on "{{on}}" {{what}}
	fi

# Apply force with verbose options
[group('apply')]
apply-verbose on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying (verbose) nix configuration on {{on}} ({{what}})..."

	# Per-target build only when buildOnTarget is set; central build otherwise.
	bot=""; [ -n "{{buildOnTarget}}" ] && bot="--build-on-target"
	if [ "${USER:-}" = "nix" ] ;then
		colmena apply ${bot} --verbose --show-trace --on "{{on}}" {{what}}
	else
		sudo -i -u nix colmena apply --config "{{workDir}}/flake.nix" ${bot} --verbose --show-trace --on "{{on}}" {{what}}
	fi

# Apply the local host configuration
[group('apply')]
apply-local what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	just update-dnf
	just _log "Applying locally ({{what}})..."
	colmena apply-local --sudo {{what}}

# Apply with rebuild silence: flag the target(s) under maintenance so
# Alertmanager inhibits their alerts during the restart, then clear the flag.
# Requires the monitoring alerting layer (dnf-maintenance ships on monitored
# nodes); on a first deploy or a non-monitored host the flag step is a no-op.
#
# Apply with the target's alerts silenced during the rebuild
[group('apply')]
apply-silenced on what='switch':
	#!/usr/bin/env bash
	set -euo pipefail
	_exec() {
		if [ "${USER:-}" = "nix" ] ;then
			colmena exec --on "{{on}}" "$@"
		else
			sudo -i -u nix colmena exec --config "{{workDir}}/flake.nix" --on "{{on}}" "$@"
		fi
	}
	just _log "Silencing alerts on {{on}}..."
	_exec dnf-maintenance on || just _warn "Could not set maintenance flag (first deploy or alerting disabled)."
	trap '_exec dnf-maintenance off || true' EXIT
	just apply "{{on}}" "{{what}}"

#==============================================================================
# Maintenance
#==============================================================================
#
# Same auto-switch pattern as the apply group: each recipe re-execs itself
# under the `nix` user when the caller is somebody else.

# When the host answers on port 22, plain ssh as usual. Otherwise it may be
# waiting in initrd for its LUKS passphrase, where sshd listens on port 2222
# (dnf/modules/system/luks.nix): probe the explicit ip (if given), the
# hostname, then the WAN IP recorded in usr/secrets/luks.json — the VPN
# route to a zone dies with its gateway, only the WAN side remains. On the
# first hit, log in as root with the nix deploy key and answer the pending
# passphrase prompt. The initrd has its own host key, regenerated by every
# reinstall, and the login is root@ — outside the `Match user nix` fleet
# policy (core.nix), so the same "never pin" options are restated here.
#
# Interactive shell to the host.
[group('manage')]
enter on ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	target="{{on}}" ; [ "{{ip}}" = "auto" ] || target="{{ip}}"
	if timeout 2 bash -c "exec 3<>/dev/tcp/$target/22" 2>/dev/null ;then
		just _log "Entering {{on}}..." "SSH"
		if [ "${USER:-}" = "nix" ]; then
			exec ssh nix@"$target"
		else
			exec sudo -i -u nix ssh nix@"$target"
		fi
	fi

	# Port 22 is down: look for an initrd sshd on every known address.
	candidates="$target"
	[ "$target" = "{{on}}" ] || candidates="$candidates {{on}}"
	wan=$(yq -r '."{{on}}".wan // ""' {{secretsDir}}/luks.json 2>/dev/null || true)
	{ [ -z "$wan" ] || [ "$wan" = "$target" ] ; } || candidates="$candidates $wan"
	for c in $candidates ;do
		if timeout 2 bash -c "exec 3<>/dev/tcp/$c/2222" 2>/dev/null ;then
			just _log "{{on}} ($c) is waiting in initrd: answering the LUKS prompt..." "SSH"
			if [ "${USER:-}" = "nix" ]; then
				exec ssh -t -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$c" \
					systemd-tty-ask-password-agent --query --watch
			else
				exec sudo -i -u nix ssh -t -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$c" \
					systemd-tty-ask-password-agent --query --watch
			fi
		fi
	done
	just _fail "{{on}} unreachable on ports 22 and 2222 (tried: $candidates)."

# Non-interactive sibling of `enter`: answers the LUKS prompt of a host waiting
# in its initrd without a human in front of it. `systemd-tty-ask-password-agent`
# only talks to a terminal, so the initrd carries a `dnf-unlock` helper that
# takes the passphrase on a pipe (dnf/modules/system/luks.nix).
#
# Called right after a reboot the machine is usually not there yet, so this
# waits (one dot per attempt) instead of failing. A host with no LUKS volume is
# a logged no-op, which is what lets `full-install` call it unconditionally.
#
# Unlock a host waiting for its LUKS passphrase in initrd
[group('manage')]
unlock host ip='' timeout='600':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just unlock "{{host}}" "{{ip}}" "{{timeout}}"
	if ! grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/disko.nix 2>/dev/null ;then
		just _log "No LUKS volume on {{host}}: nothing to unlock." "LUKS"
		exit 0
	fi
	just _check_infra_admin
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}

	# The WAN address recorded for a gateway is the only way in when the VPN
	# route to its zone died with it (same fallback as `just enter`).
	wan=$(yq -r '."{{host}}".wan // ""' {{secretsDir}}/luks.json 2>/dev/null || true)

	# 2222 first: a host that answers on both is already booted.
	answer=$(just _wait-any "{{host}}" "{{ip}}" "2222 22" "{{timeout}}")
	read -r addr port <<<"$answer"
	if [ "$port" != "2222" ] && [ -n "$wan" ] ;then
		timeout 2 bash -c ": < /dev/tcp/$wan/2222" 2>/dev/null && { addr=$wan ; port=2222 ; } || true
	fi
	if [ "$port" != "2222" ] ;then
		just _log "{{host}} already answers on 22: nothing to unlock." "LUKS"
		exit 0
	fi

	# Shared passphrase FIRST: disko formats the volume with it, and the
	# per-host keyslot is only added later by luks-passphrase-sync, from the
	# booted system — at the very first boot the shared slot is the only one
	# that exists. The per-host passphrase stays as the fallback for a host
	# installed before that was true.
	#
	# `dnf-unlock` can only report that it ANSWERED the prompt, never that the
	# passphrase was accepted: a refused one just makes systemd ask again. So
	# every attempt is confirmed from here instead.
	for key in '["luks-passphrase"]' '["luks"]["{{host}}"]["passphrase"]' ;do
		sops -d --extract "$key" {{sopsSecretsFile}} 2>/dev/null \
			| ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
				-o ConnectTimeout=10 root@"$addr" dnf-unlock >/dev/null 2>&1 || continue

		# A refused passphrase leaves the initrd up and asking again; an
		# accepted one opens the volume and switches root, taking the initrd
		# sshd with it. The port going away IS the acceptance signal — and the
		# only one available, since nothing reports back through dnf-unlock.
		#
		# 60s: unlocking is not instant on a real machine (argon2 KDF, then the
		# root filesystem mount) and calling it a refusal too early would send
		# the next passphrase into a host that is already booting.
		refused=1
		for _ in $(seq 1 30) ;do
			if ! timeout 2 bash -c ": < /dev/tcp/$addr/2222" 2>/dev/null ;then
				refused=0
				break
			fi
			sleep 2
		done
		if [ "$refused" = "1" ] ;then
			just _warn "{{host}} refused that passphrase, trying the next one."
			continue
		fi

		# Deliberately NOT waiting for port 22 here: the volume is open, which
		# is all this recipe promises. Waiting for a first boot to finish is
		# the caller's job (`full-install` does it with its own timeout), and
		# doing it twice only adds a way to fail on a host that is fine.
		just _log "{{host}} unlocked at $addr." "LUKS"
		exit 0
	done
	just _fail "Could not unlock {{host}} at $addr — try 'just enter {{host}}'."

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

# Undo the NFS home wiring left by `home/profiles/minimal/nfs.nix`: dead XDG
# symlinks removed, `<dir>.bak` restored, empty FR/EN duplicates dropped, XDG
# dirs regenerated for the current locale. On the former NFS server the data is
# repatriated from /srv/nfs/homes into each home.
#
# Run it AFTER NFS has been disabled and the host re-applied — the script
# refuses to touch a home while /mnt/nfs/homes is still mounted. `check` (the
# default) writes nothing and prints exactly what `apply` would do.
#
# `on` is a comma-separated list of hostnames, or `all` for every hive node.
#
# Clean up the homes of a host that has left NFS (check | apply)
[group('manage')]
nfs-cleanup on mode='check':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just nfs-cleanup "{{on}}" "{{mode}}"
	case "{{mode}}" in check|apply) ;; *) just _fail "mode must be 'check' or 'apply'." ;; esac
	script="{{assetsDir}}/scripts/just-nfs-cleanup.sh"
	[ -f "$script" ] || just _fail "missing $script"
	if [ "{{on}}" = "all" ] ;then
		nodes=$(just _hive-nodes)
	else
		nodes=$(echo "{{on}}" | tr ',' ' ')
	fi
	[ -n "$nodes" ] || just _fail "No target host."
	for node in $nodes ;do
		just _log "Cleaning homes on $node ({{mode}})..." "NFS"

		# `-H` gives ssh the nix user's HOME so it uses ~nix/.ssh. The script is
		# piped in rather than copied: nothing is left behind on the host.
		ssh -o BatchMode=yes nix@"$node" "sudo MODE={{mode}} bash -s" < "$script" \
			|| just _warn "$node: cleanup exited non-zero."
	done

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

# `ro` (default) watches the screen already open on the host, `rw` watches and
# takes control; both are enforced by the remote server, never by the client,
# and both fail when nobody is logged in — an admin asking to see a user's
# screen must never be silently given a different session instead. `login` is
# that other session, asked for on purpose: a GDM login screen and a desktop
# of one's own, whoever is sitting at the machine.
#
# Nothing is ever exposed on the network: the RDP listener is armed for the
# length of the session and reached through an ssh tunnel, so the fleet's
# deny-by-default firewall is left alone.
#
# Deliberately NOT re-exec'd as nix like its neighbours: only the ssh side runs
# as nix, because the FreeRDP window has to reach the caller's own Wayland
# display and nix cannot.
#
# Remote desktop (ro = view only, rw = control, login = own GDM session).
[group('manage')]
remote-desktop host mode='ro':
	#!/usr/bin/env bash
	set -euo pipefail
	case "{{mode}}" in
		ro | rw | login) ;;
		*) just _fail "mode must be 'ro', 'rw' or 'login'." ;;
	esac
	target=$(just _target "{{host}}")
	rssh() { sudo -i -u nix ssh -o ConnectTimeout=5 nix@"$target" "$@" ; }

	# Pinned to the same nixpkgs as the fleet, so the client never depends on
	# what happens to be installed on the machine running just.
	just _log "Resolving the RDP client..." "RDP"
	client=$({{nix}} build --no-link --print-out-paths --impure --expr \
		'let f = builtins.getFlake "{{workDir}}/dnf"; in f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem}.freerdp')/bin/sdl-freerdp

	just _log "Arming a {{mode}} session on {{host}} ($target)..." "RDP"
	params=$(rssh sudo dnf-remote-desktop start "{{mode}}") \
		|| just _fail "could not arm a {{mode}} session on {{host}}: is the remote-desktop enabled there? who is logged?"
	get() { printf '%s\n' "$params" | sed -n "s/^$1=//p" | head -n1 ; }

	# The remote port is fixed by the port registry; the local one only has to
	# be free here.
	lport=3389
	while timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$lport" 2>/dev/null ;do
		lport=$((lport + 1))
	done
	ctl=$(mktemp -u /tmp/dnf-rd-XXXXXXXX)

	# Client closed, ctrl-c or failure: the host disarms and the tunnel goes.
	# The host keeps its own timeout as a last resort if this machine dies.
	cleanup() {
		sudo -i -u nix ssh -S "$ctl" -O exit nix@"$target" 2>/dev/null || true
		rssh sudo dnf-remote-desktop stop >/dev/null 2>&1 || true
	}
	trap cleanup EXIT

	sudo -i -u nix ssh -M -S "$ctl" -f -N -o ExitOnForwardFailure=yes \
		-L "127.0.0.1:$lport:127.0.0.1:$(get port)" nix@"$target"
	if [ "$(get backend)" = login ] ;then
		just _warn "GDM login screen: you get your OWN session, not the screen on the monitor."
	fi
	just _log "$(get backend) session, closing itself in $(get timeout) min." "RDP"

	# Arguments through a pipe rather than argv: the password stays out of ps.
	"$client" /args-from:fd:3 3< <(
		echo "/v:127.0.0.1:$lport"
		echo "/t:{{host}} ({{mode}})"
		echo "/network:lan"

		# AVC444 asserts on an odd-width region and *aborts* the encoder
		# (prim_YUV.c, RGBToAVC444YUVv2_BGRX_DOUBLE_ROW). gnome-remote-desktop
		# never hands it one; freerdp-shadow-cli does, and dies mid-session —
		# taking the pointer updates with it. Let GFX negotiate there instead.
		if [ "$(get backend)" = x11 ] ;then
			echo "/gfx"
		else
			echo "/gfx:AVC444"
		fi

		# Mirroring a physical monitor, the server cannot resize anything, so
		# `+dynamic-resolution` would leave the client showing the top-left
		# crop of a desktop larger than its default 1024x768 window. The
		# client has to adapt instead. Opening at the REMOTE resolution maps
		# one pixel to one pixel: right aspect ratio, and no resampling blur.
		# Fullscreen is then exact whenever both screens match. Smart-sizing
		# still follows every manual resize. Falling back to a share of the
		# local screen when the host could not report its geometry costs the
		# aspect ratio, not the session.
		# A login session is a virtual monitor the server CAN resize, so there
		# the client dictates the resolution and gets a crisp 1:1.
		if [ "$(get backend)" = login ] ;then
			echo "+dynamic-resolution"
		else
			geom=$(get geometry)
			if [ -n "$geom" ] ;then
				echo "/size:$geom"
			else
				echo "/size:100%"
			fi
			echo "/smart-sizing"
		fi

		if [ -n "$(get username)" ] ;then
			echo "/u:$(get username)"
			echo "/p:$(get password)"
		fi

		# freerdp-shadow-cli mints its own certificate and runs with client
		# authentication off; the login daemon hands the client over to a
		# session presenting yet another one. So pin only the certificate we
		# generated ourselves: elsewhere the loopback tunnel carries the trust.
		[ "$(get backend)" != x11 ] || echo "/sec:tls"
		if [ -n "$(get fingerprint)" ] ;then
			echo "/cert:fingerprint:sha256:$(get fingerprint)"
		else
			echo "/cert:ignore"
		fi
	)

# Run all checks and tests (useful before deploy)
[group('check')]
check-all:
	#!/usr/bin/env bash
	set -euo pipefail
	if [ -d {{workDir}}/dnf ] ;then
		just _log "DNF Unit Tests" "CHECK-ALL"
		cd {{workDir}}/dnf && just unit-tests | grep -v '✅'
	fi
	just _log "Network flake" "CHECK-ALL"
	cd {{workDir}} && just check-flake
