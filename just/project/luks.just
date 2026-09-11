# DNF just — LUKS: provisioning, audit, remote unlock.

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
[group('luks')]
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

		# `sudo tee`, never `sudo cmd > file`: a remote redirection runs in the nix
		# user's shell, which cannot write into the root-only key directory.
		sops -d --extract '["luks"]["{{host}}"]["initrd-key"]' {{sopsSecretsFile}} \
			| ssh nix@"$target" 'sudo mkdir -p /var/lib/luks-initrd && base64 -d | sudo tee /var/lib/luks-initrd/ssh_host_ed25519_key >/dev/null'
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
[group('luks')]
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
