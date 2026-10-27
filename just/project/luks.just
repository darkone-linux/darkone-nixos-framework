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
#           is missing, record the gateway public address so `just unlock`
#           still finds the initrd sshd when the VPN is down, and bootstrap the
#           shared keyslot of a host installed before the shared-format era.
#           Behind a box (NAT), pass that address as `wan` (IP or DDNS name).
# - `passwd` rotate the per-host passphrase, then converge.
# - `show`  read-only audit: keyslot table + remote-unlock conformity.
#
# There is no install passphrase to retype: `just install` formats the volume
# with the shared one (nixos-anywhere --disk-encryption-keys), so the format
# keyslot IS the shared keyslot. See dnf/modules/system/luks.nix.
#
# An isolated host has no shared slot: formatted with its own passphrase, its
# `luks/<host>/*` in its own file (`_luks-store`), `passwd` rotated from here.
#
# LUKS provisioning & info. Actions: pre, passwd, show
[group('luks')]
luks host action='' ip='auto' wan='':
	#!/usr/bin/env bash
	set -euo pipefail

	# `env`: sudo resets the environment, and `full-install` mutes the closing
	# hint through DNF_FULL_INSTALL.
	[ "${USER:-}" = "nix" ] || exec sudo -u nix env DNF_FULL_INSTALL="${DNF_FULL_INSTALL:-}" \
		just luks "{{host}}" "{{action}}" "{{ip}}" "{{wan}}"
	case "{{action}}" in ''|pre|passwd|show) ;; *) just _fail "Unknown action '{{action}}' — valid: pre, passwd, show" ;; esac
	manifest={{secretsDir}}/luks.json
	hostconf=$(just _host_conf "{{host}}")
	[ -n "$hostconf" ] || just _fail "Unknown host '{{host}}' (see etc/config.yaml)."

	# No LUKS = no-op: keeps the recipe safely callable from `just configure`.
	if ! grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/install/disko.nix 2>/dev/null ;then
		just _log "No LUKS volume on {{host}}: nothing to do." "LUKS"
		exit 0
	fi
	[ -f {{sopsSecretsFile}} ] || just _fail "No sops secrets file: run 'just configure-admin-host' first."
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}

	# `luks/<host>/*` of an isolated host lives in its own file: no fleet
	# secret ever goes through that host (`hsops`, never the shared slot).
	s=$(just _luks-store "{{host}}") ; read -r store storekey <<<"$s"
	isolated=false ; [ "$store" = {{sopsSecretsFile}} ] || isolated=true
	hsops() { SOPS_AGE_KEY_FILE="$storekey" sops "$@" ; }

	#--------------------------------------------------------------------------
	# Offline phase (`pre`): everything that must exist before the build
	#--------------------------------------------------------------------------

	if [ "{{action}}" != "show" ] ;then
		just _sops_before_edit

		# Shared passphrase: asked once fleet-wide. It authorizes keyslot
		# management (same slot `just yubikey` uses) and is what disko formats
		# every encrypted volume with.
		if ! $isolated && ! sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
			echo -n "Shared LUKS passphrase (unlocks every encrypted host): "
			read -s LP ; echo
			[ -n "$LP" ] || just _fail "Empty passphrase."
			sops set {{sopsSecretsFile}} '["luks-passphrase"]' "\"$LP\""
		fi

		# A host turned isolated starts over in its own file: its former
		# entries open nothing it boots after the reinstall.
		if $isolated && sops -d --extract '["luks"]["{{host}}"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
			just _warn "Stale luks/{{host}} in secrets.yaml ({{host}} is isolated): delete it with 'just sops' once reinstalled."
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

			# No sync unit on an isolated host: the target phase rotates the
			# keyslot first, sops follows.
			if $isolated ;then
				NEWPP=$PP
			else
				sops set {{sopsSecretsFile}} '["luks"]["{{host}}"]["passphrase"]' "\"$PP\""
			fi
		elif ! hsops -d --extract '["luks"]["{{host}}"]["passphrase"]' "$store" >/dev/null 2>&1 ;then
			hsops set "$store" '["luks"]["{{host}}"]["passphrase"]' \
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
		if ! hsops -d --extract '["luks"]["{{host}}"]["initrd-key"]' "$store" >/dev/null 2>&1 ;then
			# /run itself is root-only; fall back to TMPDIR for the few seconds
			# the private key exists outside sops.
			rt="${XDG_RUNTIME_DIR:-}" ; [ -n "$rt" ] && [ -d "$rt" ] || rt=$(dirname "$(mktemp -u)")
			tmp=$(mktemp -d -p "$rt" dnf-luks-XXXXXX) ; chmod 700 "$tmp"
			trap 'rm -rf "$tmp"' EXIT
			ssh-keygen -t ed25519 -N "" -q -f "$tmp/key"
			hsops set "$store" '["luks"]["{{host}}"]["initrd-key"]' \
				"\"$(base64 -w0 < "$tmp/key")\""

			# `-y` and not the .pub file: same derived form the convergence
			# compares against, so a match is a match.
			hsops set "$store" '["luks"]["{{host}}"]["initrd-key-pub"]' \
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
		[ -z "${NEWPP:-}" ] || just _fail "{{host}} unreachable at $target: its keyslot rotates first, nothing changed."
		just _warn "{{host}} unreachable at $target: re-run 'just luks {{host}}' once it is up, BEFORE any apply."
		exit 0
	fi

	SHARED="" ; $isolated || SHARED=$(sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}})
	PERHOST=$(hsops -d --extract '["luks"]["{{host}}"]["passphrase"]' "$store")

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

	# Adds keyslot $2 to device $3, authorized by $1: old key on stdin, new key
	# via a root-only tmpfs file, both wiped.
	add_key() {
		printf '%s\n%s\n' "$1" "$2" | ssh nix@"$target" "sudo bash -c 'IFS= read -r cur; IFS= read -r new; t=\$(mktemp -p /run); chmod 600 \"\$t\"; printf %s \"\$new\" >\"\$t\"; rc=0; printf %s \"\$cur\" | cryptsetup luksAddKey --key-file=- $3 \"\$t\" >/dev/null 2>&1 || rc=1; rm -f \"\$t\"; exit \$rc'"
	}

	if [ "{{action}}" = "show" ] ;then
		just _luks-show "{{host}}" "$target" "$store" "$storekey"
		exit 0
	fi

	# Isolated `passwd`: its one passphrase also authorizes its rotation, so no
	# unit can do it at apply. New slot added, stored, old slot killed: a
	# stored value opens the volume at every step.
	if [ -n "${NEWPP:-}" ] ;then
		[ "$NEWPP" != "$PERHOST" ] || just _fail "Same passphrase as the current one: nothing to rotate."
		declare -A oldslot=()
		for dev in $devs ;do
			oldslot[$dev]=$(slot_of "$PERHOST" "$dev")
			[ -n "${oldslot[$dev]}" ] || just _fail "$dev refuses the stored passphrase of {{host}}: nothing rotated."
		done
		for dev in $devs ;do
			add_key "$PERHOST" "$NEWPP" "$dev" || just _fail "luksAddKey failed on $dev: sops unchanged."
		done
		just _sops_before_edit
		hsops set "$store" '["luks"]["{{host}}"]["passphrase"]' "\"$NEWPP\""
		just _fix_fs_permissions
		for dev in $devs ;do
			printf '%s' "$NEWPP" | ssh nix@"$target" "sudo cryptsetup luksKillSlot -q --key-file=- '$dev' ${oldslot[$dev]}" \
				|| just _warn "$dev: old slot ${oldslot[$dev]} left in place (still opens with the old passphrase)."
		done
		PERHOST=$NEWPP
		just _log "Passphrase of {{host}} rotated on $(echo $devs)." "LUKS"
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
	sopspub=$(hsops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' "$store" 2>/dev/null || true)
	if [ -n "$targetpub" ] && [ "$targetpub" != "$sopspub" ] ;then
		just _log "Adopting the initrd host key already installed on {{host}}..." "LUKS"
		just _sops_before_edit
		hsops set "$store" '["luks"]["{{host}}"]["initrd-key"]' \
			"\"$(ssh nix@"$target" 'sudo base64 -w0 /var/lib/luks-initrd/ssh_host_ed25519_key')\""
		hsops set "$store" '["luks"]["{{host}}"]["initrd-key-pub"]' "\"$targetpub\""
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
		hsops -d --extract '["luks"]["{{host}}"]["initrd-key"]' "$store" \
			| ssh nix@"$target" 'sudo mkdir -p /var/lib/luks-initrd && base64 -d | sudo tee /var/lib/luks-initrd/ssh_host_ed25519_key >/dev/null'
		hsops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' "$store" \
			| ssh nix@"$target" 'sudo tee /var/lib/luks-initrd/ssh_host_ed25519_key.pub >/dev/null'
		ssh nix@"$target" 'sudo chown -R root:root /var/lib/luks-initrd \
			&& sudo chmod 700 /var/lib/luks-initrd \
			&& sudo chmod 600 /var/lib/luks-initrd/ssh_host_ed25519_key \
			&& sudo chmod 644 /var/lib/luks-initrd/ssh_host_ed25519_key.pub'
	fi

	# Gateways: record the public address. The VPN route to a zone dies with
	# its gateway, so `just unlock` (`_enter_initrd`) falls back to this
	# address to reach the initrd sshd. Refreshed at each run (ISP renumbering needs a
	# re-run). The gateway hostname comes from var/generated/network.nix (same
	# source as the luks module): the raw config.yaml does not carry it, the
	# generator derives it from the host profiles.
	zone=$(echo "$hostconf" | yq -p=json -r '.zone // ""')
	zone="${zone%%:*}"
	wanif=$(yq -r ".zones.\"$zone\".gateway.wan.interface // \"\"" {{workDir}}/etc/config.yaml)
	gwhost=$({{nix}} eval --impure --raw \
		--expr "(import {{workDir}}/var/generated/network.nix).zones.\"$zone\".gateway.hostname or \"\"" 2>/dev/null || echo "")
	if [ -n "$wanif" ] && [ "$gwhost" = "{{host}}" ] ;then
		ifaddr=$(ssh nix@"$target" "ip -4 -o addr show dev '$wanif' scope global" 2>/dev/null \
			| awk '{print $4}' | cut -d/ -f1 | head -1)

		# Behind a box the interface holds a private address, useless from the
		# Internet: explicit `wan` first, then a public interface address, then
		# the target itself when it was reached on a public IP (box forward).
		wan="{{wan}}"
		if [ -z "$wan" ] && [ -n "$ifaddr" ] && just _is-public-ipv4 "$ifaddr" 2>/dev/null ;then
			wan=$ifaddr
		elif [ -z "$wan" ] && just _is-public-ipv4 "$target" 2>/dev/null ;then
			wan=$target
		fi
		if [ -n "$wan" ] ;then
			# The earlier _fix_fs_permissions restored usr/secrets/ ownership:
			# reopen it for the manifest write, restore right after.
			just _sops_before_edit
			WAN="$wan" yq -i -p=json -o=json '."{{host}}".wan = strenv(WAN)' "$manifest"
			just _fix_fs_permissions
			just _log "Public address of {{host}} recorded: $wan" "LUKS"
		else
			just _warn "{{host}} sits behind NAT (${ifaddr:-no WAN address}): public address not recorded. Forward 2222 on the box, then: just luks {{host}} '' auto <public IP or DDNS name>"
		fi
	fi

	# Legacy bootstrap. A volume formatted before the shared-passphrase era
	# accepts neither managed passphrase, and the sync/enroll units cannot
	# authorize anything without one: add the shared slot here, with the
	# passphrase that was typed at that install. Never happens on a host
	# installed by the current `just install`.
	fixed=""
	for dev in $devs ;do
		if { ! $isolated && [ -n "$(slot_of "$SHARED" "$dev")" ] ; } || [ -n "$(slot_of "$PERHOST" "$dev")" ] ;then
			just _log "$dev already accepts a managed passphrase." "LUKS"
			continue
		fi

		# Never asked for an isolated host: the only other passphrase its disk
		# could hold is a fleet one, not to be typed into it.
		! $isolated || just _fail "$dev of isolated {{host}} refuses its own passphrase: reinstall it with 'just install {{host}}'."
		just _warn "$dev accepts no managed passphrase: host installed before the shared format."
		if [ -z "${INSTALL:-}" ] ;then
			echo -n "Legacy install passphrase of {{host}}: "
			read -s INSTALL ; echo
			[ -n "$INSTALL" ] || just _fail "Empty passphrase."
		fi
		add_key "$INSTALL" "$SHARED" "$dev" || just _fail "luksAddKey failed on $dev (wrong install passphrase?)."
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

	# `full-install` commits and applies right after.
	[ -n "${DNF_FULL_INSTALL:-}" ] || just _log "If luks.json changed: git add usr/secrets/luks.json && git commit ... && just apply {{host}}" "LUKS"

# Where `luks/<host>/*` lives, as `<sops file> <age key file>`: the fleet file
# under the infra key, or an isolated host's own file under the admin key (the
# infra key is no recipient there).
_luks-store host:
	#!/usr/bin/env bash
	set -euo pipefail

	# As nix: the admin key path is the home of whoever runs this, and nix
	# reads it.
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just _luks-store "{{host}}"
	isolated=$({{nix}} eval --json "{{workDir}}#nixosConfigurations.{{host}}.config.darkone.system.sops.isolated" 2>/dev/null) \
		|| just _fail "Cannot evaluate {{host}}: unknown where its LUKS secrets live."
	if [ "$isolated" != true ] ;then
		echo "{{sopsSecretsFile}} {{sopsInfraKeyFile}}"
	elif [ -f {{secretsDir}}/hosts/{{host}}.yaml ] ;then
		echo "{{secretsDir}}/hosts/{{host}}.yaml {{sopsAdminKeyFile}}"
	else
		just _fail "No secrets file for isolated {{host}}: 'just install {{host}}' or 'just space-init {{host}}' seals it."
	fi

# Implementation of `just luks <host> show`: keyslot table + remote-unlock audit.
#
# Live verification wherever it is possible — every managed passphrase is
# actually tested against the header, so the table shows what the volume accepts
# today, not what a ledger remembers. Exits non-zero when a check fails, so the
# recipe can be dropped into a script.
#
# Column widths are computed, never hard-coded: a device path or a YubiKey name
# is as long as it happens to be.
_luks-show host target store storekey:
	#!/usr/bin/env bash
	set -euo pipefail
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}
	isolated=false ; [ "{{store}}" = {{sopsSecretsFile}} ] || isolated=true
	hsops() { SOPS_AGE_KEY_FILE="{{storekey}}" sops "$@" ; }

	# Never the shared passphrase into an isolated host, not even as a test.
	shared="" ; $isolated || shared=$(sops -d --extract '["luks-passphrase"]' {{sopsSecretsFile}})
	perhost=$(hsops -d --extract '["luks"]["{{host}}"]["passphrase"]' "{{store}}")
	failures=0
	pass() { printf '  {{GREEN}}OK{{NORMAL}}    %s\n' "$1" ; }
	fail() { printf '  {{RED}}FAIL{{NORMAL}}  %s\n' "$1" ; failures=$((failures + 1)) ; }
	warn() { printf '  {{YELLOW}}WARN{{NORMAL}}  %s\n' "$1" ; }
	note() { printf '  NOTE  %s\n' "$1" ; }

	# Token and registry may spell the same credential in either base64 flavour
	# (standard or url-safe, padded or not): fold both to one form to compare.
	b64norm() { tr '+/' '-_' | tr -d '=' ; }

	# Salts too: an isolated host must answer at its own ones only (`-` for an
	# empty field, which tab-splitting would collapse).
	declare -A credname=() fleetsalt=() ownsalt=()
	if [ -f {{secretsDir}}/yubikeys.json ] ;then
		while IFS=$'\t' read -r label cred salt own ;do
			[ "$cred" != - ] || continue
			credname["$(printf %s "$cred" | b64norm)"]=$label
			[ "$salt" = - ] || fleetsalt["$(printf %s "$salt" | b64norm)"]=$label
			[ "$own" = - ] || ownsalt[$label]=$(printf %s "$own" | b64norm)
		done < <(yq -p=json -o=tsv '
			to_entries | .[] as $u | $u.value | to_entries | .[]
			| [$u.key + "/" + .key, .value.credId // "-", .value.salt // "-", .value.hostSalts."{{host}}" // "-"]' {{secretsDir}}/yubikeys.json)
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
		sharedslot="" ; $isolated || sharedslot=$(slot_of "$shared")
		hostslot=$(slot_of "$perhost")

		# slot -> "content|source" for every slot we can name.
		declare -A content=() origin=() salted=()
		[ -z "$sharedslot" ] || { content[$sharedslot]="Shared passphrase" ; origin[$sharedslot]="sops luks-passphrase" ; }
		[ -z "$hostslot" ] || { content[$hostslot]="Host passphrase" ; origin[$hostslot]="sops luks/{{host}}/passphrase" ; }
		while IFS=$'\t' read -r ttype cred tsalt tslots ;do
			[ "$ttype" = "systemd-fido2" ] || continue
			label=${credname[$(printf %s "$cred" | b64norm)]:-unregistered}
			tsalt=$(printf %s "$tsalt" | b64norm)
			for s in ${tslots//,/ } ;do
				content[$s]="YubiKey $label"
				origin[$s]="systemd-fido2 token"
				$isolated || continue
				if [ -n "${fleetsalt[$tsalt]:-}" ] ;then salted[$s]=fleet
				elif [ "${ownsalt[$label]:-}" = "$tsalt" ] ;then salted[$s]=own
				else salted[$s]=stale
				fi
			done
		done < <(printf '%s' "$meta" | yq -p=json -o=tsv '
			.tokens // {} | to_entries | .[]
			| [.value.type, .value."fido2-credential" // "-", .value."fido2-salt" // "-", (.value.keyslots // [] | join(","))]')

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
				YubiKey*)
					case "${salted[$s]:-}" in
						fleet) check="FLEET SALT" ;;
						stale) check="salt not in yubikeys.json" ;;
						own) check="enrolled, own salt" ;;
						*) check="enrolled" ;;
					esac ;;
				Unknown) check="not managed by DNF" ;;
			esac
			printf "  %-4s  %-${w2}s  %-${w3}s  %s\n" "$s" "$c" "$o" "$check"
		done
		printf '  Slots in use: %s/32\n' "${#slots[@]}"

		# A managed passphrase that opens nothing is the one failure that locks
		# the fleet out of the machine.
		[ -n "$sharedslot" ] || $isolated || fail "$dev: the shared passphrase does not open this volume"
		[ -n "$hostslot" ] || fail "$dev: the per-host passphrase does not open this volume (apply the host?)"
		for s in "${!salted[@]}" ;do
			[ "${salted[$s]}" != fleet ] \
				|| fail "$dev: keyslot $s answers at the fleet salt, one touch here yields the value opening every other disk"
		done

		# The ledger drives rotation: a stale entry silently kills the wrong
		# slot at the next passphrase change. None on an isolated host (no
		# sync unit).
		for entry in "shared:$sharedslot" "host:$hostslot" ;do
			label=${entry%%:*} ; live=${entry#*:}
			{ [ -n "$live" ] && ! $isolated ; } || continue
			recorded=$(printf '%s\n' "$ledger" | awk -v l="$label" -v d="$dev" '$1 == l && $2 == d {print $4}' | tail -n1)
			[ -n "$recorded" ] || { warn "$dev: $label slot $live is not in the ledger yet (apply the host)" ; continue ; }
			[ "$recorded" = "$live" ] && continue
			fail "$dev: ledger says $label is slot $recorded, the volume answers on $live"
		done
	done

	# Not an error: a key away from the admin host is enrolled here once
	# captured, the passphrase stays meanwhile.
	if $isolated ;then
		away=""
		for label in "${credname[@]}" ;do
			[ -n "${ownsalt[$label]:-}" ] || away="$away $label"
		done
		[ -z "$away" ] || note "not captured for {{host}} yet:$away (plug it, 'just yubikey <user> <key>')"
	fi

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
		backup=$(hsops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' "{{store}}" 2>/dev/null \
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

	# sshd on 2222 is useless without a link, and `availableKernelModules` only
	# ships NIC drivers: a NIC hanging off a bus driver (virtio_net behind
	# virtio_pci) also needs its transport, absent from the module closure until
	# something asks for it. Compare what the live NICs bind to with what the
	# initrd carries — the host otherwise waits forever, silently.
	closure=$({{nix}} build --no-link --print-out-paths \
		{{workDir}}#nixosConfigurations."{{host}}".config.system.build.modulesClosure 2>/dev/null || true)
	if [ -z "$closure" ] ;then
		warn "could not build the module closure: initrd NIC drivers unverified"
	else

		drivers=$(just _nic-drivers "{{target}}" || true)
		missing=""
		for m in $drivers ;do

			# modules.dep spells the same module with `_` or `-`: `?` matches both.
			find "$closure/lib/modules" -name "${m//_/?}.ko*" | grep -q . \
				|| missing="$missing $m"
		done
		if [ -z "$drivers" ] ;then
			warn "no wired NIC found on the target: remote unlock needs one"
		elif [ -z "$missing" ] ;then
			pass "the initrd carries every driver the live NICs use ($(echo $drivers))"
		else
			fail "the initrd has no$missing: no network in stage 1, nothing answers on $port (just detect-hw {{host}}, then apply)"
		fi
	fi

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

	# The colmena node, not `nixosConfigurations`: the hive imports nixpkgs without
	# its flake revision (`pre-git` version), so the two toplevels never match and
	# every deployed host looked out of date.
	built=$({{nix}} eval --raw --impure --expr '(builtins.getFlake "git+file://{{workDir}}").colmenaHive.nodes."{{host}}".config.system.build.toplevel.outPath' 2>/dev/null || echo "")
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
		if [ -z "$wan" ] ;then
			fail "no WAN address recorded: unreachable in initrd once the VPN is down"

		# Recorded before public addresses were told apart: a box-side IP.
		elif [[ "$wan" =~ ^[0-9.]+$ ]] && ! just _is-public-ipv4 "$wan" 2>/dev/null ;then
			fail "recorded WAN address $wan is private: re-run 'just luks {{host}} \"\" auto <public address>'"
		else
			pass "gateway WAN address recorded ($wan)"
		fi
	fi

	echo
	[ "$failures" -eq 0 ] || just _fail "$failures check(s) failed on {{host}}."
	just _log "{{host}} is conform." "LUKS"

# Stored passphrases first, piped to the initrd `dnf-unlock` helper: no human
# needed. None accepted, or no infra key here: the interactive prompt, when a
# terminal is there (`_enter_initrd`).
#
# Waits for the host (one dot per attempt): called right after a reboot. No LUKS
# volume: a logged no-op, so `full-install` calls it unconditionally.
#
# Unlock a host waiting for its LUKS passphrase in initrd
[group('luks')]
unlock host ip='' timeout='600':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just unlock "{{host}}" "{{ip}}" "{{timeout}}"
	if ! grep -q '"luks"' {{workDir}}/usr/machines/{{host}}/install/disko.nix 2>/dev/null ;then
		just _log "No LUKS volume on {{host}}: nothing to unlock." "LUKS"
		exit 0
	fi
	stored=true
	s=$(just _luks-store "{{host}}") ; read -r store storekey <<<"$s"
	if [ ! -f "$storekey" ] ;then
		[ -t 0 ] || just _fail "No $storekey here: run 'just unlock {{host}}' from the admin host."
		just _warn "No $storekey here: the passphrase will be asked."
		stored=false
	fi
	export SOPS_AGE_KEY_FILE=$storekey

	# Pinned initrd host key (M8): no passphrase for a sshd on 2222 that cannot
	# prove it is this initrd. `HostKeyAlias`: one entry, whatever address
	# answers (IP, name, WAN).
	pub=$(sops -d --extract '["luks"]["{{host}}"]["initrd-key-pub"]' "$store" 2>/dev/null) || pub=""
	[ -n "$pub" ] || just _fail "Initrd host key of {{host}} unreadable from sops: nothing sent. Unlock at the console, then 'just luks {{host}}' from the admin host."
	kh=$(mktemp) ; trap 'rm -f "$kh"' EXIT
	echo "initrd-{{host}} $pub" >"$kh"
	pin=(-p 2222 -o HostKeyAlias="initrd-{{host}}" -o UserKnownHostsFile="$kh"
		-o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes)

	# The WAN address recorded for a gateway is the only way in when the VPN
	# route to its zone died with it (same fallback as `_enter_initrd`).
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

	# Checked once here for a clear verdict; every connection below enforces it
	# again (`StrictHostKeyChecking=yes`). `#` lines: the banner ssh-keyscan
	# prints on stdout.
	seen=$( { ssh-keyscan -p 2222 -T 10 -t ed25519 "$addr" 2>/dev/null || true ; } | awk '/^[^#]/ {print $2, $3; exit}')
	[ -n "$seen" ] || just _fail "{{host}} ($addr): no initrd host key read on 2222, nothing sent."
	[ "$seen" = "$(awk '{print $1, $2}' <<<"$pub")" ] \
		|| just _fail "{{host}} ($addr) shows another initrd host key than sops on 2222: nothing sent. Not an impostor? Unlock at the console, then 'just luks {{host}}'."

	# Shared passphrase FIRST: disko formats the volume with it, and the
	# per-host keyslot is only added later by luks-passphrase-sync, from the
	# booted system — at the very first boot the shared slot is the only one
	# that exists. The per-host passphrase stays as the fallback for a host
	# installed before that was true. An isolated host: its own one only.
	#
	# `dnf-unlock` can only report that it ANSWERED the prompt, never that the
	# passphrase was accepted: a refused one just makes systemd ask again. So
	# every attempt is confirmed from here instead.
	keys=()
	if $stored ;then
		[ "$store" != {{sopsSecretsFile}} ] || keys=('["luks-passphrase"]')
		keys+=('["luks"]["{{host}}"]["passphrase"]')
	fi
	for key in "${keys[@]}" ;do
		sops -d --extract "$key" "$store" 2>/dev/null \
			| ssh "${pin[@]}" -o ConnectTimeout=10 root@"$addr" dnf-unlock >/dev/null 2>&1 || continue

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
	! $stored || just _warn "No stored passphrase accepted by {{host}}."
	[ -t 0 ] || just _fail "Could not unlock {{host}} at $addr: run 'just unlock {{host}}' from a terminal to type it."

	# No `exec`: the EXIT trap removes the pin file.
	just _enter_initrd "{{host}}" "$addr" "$kh"

# Interactive LUKS prompt of a host waiting in initrd (sshd on 2222): probe the
# explicit ip, the hostname, then the WAN IP of usr/secrets/luks.json — the VPN
# route to a zone dies with its gateway. root@, outside the `Match user nix`
# policy: the initrd host key is pinned by `known_hosts`, built by `unlock`.
_enter_initrd host ip known_hosts:
	#!/usr/bin/env bash
	set -euo pipefail
	candidates="{{ip}}"
	[ "{{ip}}" = "{{host}}" ] || candidates="$candidates {{host}}"
	wan=$(yq -r '."{{host}}".wan // ""' {{secretsDir}}/luks.json 2>/dev/null || true)
	{ [ -z "$wan" ] || [ "$wan" = "{{ip}}" ] ; } || candidates="$candidates $wan"
	for c in $candidates ;do
		if timeout 2 bash -c "exec 3<>/dev/tcp/$c/2222" 2>/dev/null ;then
			just _log "{{host}} ($c) is waiting in initrd: answering the LUKS prompt..." "LUKS"
			ssh=(ssh -t -p 2222 -o HostKeyAlias="initrd-{{host}}" -o UserKnownHostsFile="{{known_hosts}}"
				-o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes root@"$c"
				systemd-tty-ask-password-agent --query --watch)
			if [ "${USER:-}" = "nix" ]; then
				exec "${ssh[@]}"
			else
				exec sudo -i -u nix "${ssh[@]}"
			fi
		fi
	done
	just _fail "{{host}}: no initrd answering on port 2222 (tried:$candidates)."

# Succeeds when `addr` is a public IPv4 literal, the only kind a box port
# forward answers on: private, CGNAT/tailnet (100.64/10), loopback and
# link-local ranges fail, and so does a hostname.
_is-public-ipv4 addr:
	#!/usr/bin/env bash
	set -euo pipefail
	[[ "{{addr}}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || exit 1
	a=${BASH_REMATCH[1]} ; b=${BASH_REMATCH[2]}
	case "$a" in
		0|10|127) exit 1 ;;
		172) [ "$b" -lt 16 ] || [ "$b" -gt 31 ] || exit 1 ;;
		192) [ "$b" -ne 168 ] || exit 1 ;;
		100) [ "$b" -lt 64 ] || [ "$b" -gt 127 ] || exit 1 ;;
		169) [ "$b" -ne 254 ] || exit 1 ;;
	esac
