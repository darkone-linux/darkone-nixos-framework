# DNF just — secrets: sops, passwords, YubiKeys, infra key rotation.

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

# Edit sops secrets
[group('secrets')]
sops:
	#!/usr/bin/env bash
	set -euo pipefail
	just _sops_before_edit
	sudo -i -u nix EDITOR=vim sops {{sopsSecretsFile}} || true
	just _fix_fs_permissions

# Record the fleet default password (hash only, sops). Configures no account:
# `just passwd <login>` is what opens a session with it.
[group('secrets')]
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
[group('secrets')]
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
[group('secrets')]
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

# Rotate the infra age key (step: init | push-keys | finalize)
[group('secrets')]
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
