# DNF just — identities: Kanidm replication.

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
[group('identities')]
idm-sync-certs:
	#!/usr/bin/env bash
	set -euo pipefail
	dest="{{secretsDir}}/replication"
	mkdir -p "$dest"

	# TODO: probe the HCS and the gateways only — walking 150 nodes is slow.
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
[group('identities')]
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

	just _log "Kanidm replication diagnosis (supplier=$supplier)" "IDM"

	# Local: every cert must exist AND be git-tracked, else the flake eval ignores it.
	for n in "$supplier" "${consumers[@]}" ;do
		if [ ! -f "$dest/$n.pem" ] ;then
			just _warn "Cert $n.pem missing (never synced)." ; ok=0
		elif ! git -C {{workDir}} ls-files --error-unmatch "$dest/$n.pem" >/dev/null 2>&1 ;then
			just _warn "Cert $n.pem NOT tracked by git → invisible to the flake ('git add' needed)." ; ok=0
		fi
	done

	# Supplier: service up, cert in sync, database referential integrity.
	just _log "Supplier $supplier" "IDM"
	act=$(on "$supplier" 'systemctl is-active kanidm')
	just _info "kanidm: ${act:-unreachable}" "IDM"
	[ "$act" = "active" ] || ok=0
	live=$(repl_cert "$supplier") ; sync=$(synced_cert "$supplier")
	if [ -z "$live" ] ;then
		just _warn "No live replication cert on $supplier." ; ok=0
	elif [ "$live" != "$sync" ] ;then
		just _warn "Live HCS cert ≠ synced cert → consumers in UnknownCA (re-sync needed)." ; ok=0
	else
		just _info "Replication cert in sync." "IDM"
	fi
	verify=$(on "$supplier" 'sudo kanidmd database verify -c /etc/kanidm/server.toml 2>&1')
	if printf '%s' "$verify" | grep -qE 'RefintNotUpheld|Err\(' ;then
		just _err "HCS database integrity: FAILED (dangling references):"
		printf '%s\n' "$verify" | grep -E 'RefintNotUpheld|Err\(' | sed 's/^/      /'
		refint_fail=1 ; ok=0
	else
		just _info "HCS database integrity: OK." "IDM"
	fi

	# Consumers: service up, role, supplier_cert freshness, last refresh outcome.
	for c in "${consumers[@]}" ;do
		just _log "Consumer $c" "IDM"
		act=$(on "$c" 'systemctl is-active kanidm')
		role=$(on "$c" "grep -oE '^role[[:space:]]*=.*' /etc/kanidm/server.toml")
		just _info "kanidm: ${act:-unreachable} | ${role:-unknown role}" "IDM"
		[ "$act" = "active" ] || ok=0
		conf=$(on "$c" "grep -oE 'MII[A-Za-z0-9+/=_-]+' /etc/kanidm/server.toml | head -n1")
		if [ -n "$sync" ] && [ -n "$conf" ] && [ "$conf" != "$sync" ] ;then
			just _warn "supplier_cert of $c is stale (≠ current HCS cert) → UnknownCA." ; ok=0
		fi
		jr=$(on "$c" 'journalctl -u kanidm --since -10min --no-pager')
		if printf '%s' "$jr" | grep -q 'ReferentialIntegrity' ;then
			just _warn "Last refresh: FAILED referential integrity (supplier corruption)." ; ok=0
		elif printf '%s' "$jr" | grep -q 'UnknownCA' ;then
			just _warn "Last refresh: FAILED UnknownCA (stale cert)." ; ok=0
		elif printf '%s' "$jr" | grep -qE 'consumer_apply_refresh|Reindexed' ;then
			just _info "Last refresh: OK." "IDM"
		else
			just _info "Last refresh: none recently." "IDM"
		fi
	done

	# Verdict + prescription (printed only; nothing is executed).
	if [ "$ok" = 1 ] ;then
		just _log "Replication healthy — nothing to do. ✅" "IDM"
		exit 0
	fi
	just _warn "Replication NOT healthy — prescription below:"
	echo
	if [ "$refint_fail" = 1 ] ;then
		echo "  [HCS] Corrupted database (RefintNotUpheld): every refresh fails until"
		echo "  it is repaired, and kanidm has no 'repair refint'."
		echo "  Remedy: RESTORE the HCS database from a HEALTHY backup (older than the"
		echo "  corruption — a recent backup may already be corrupted), then resync"
		echo "  the cert (the restore may change it):"
		echo
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo systemctl stop kanidm'"
		echo "    #  ... restore /var/lib/kanidm/kanidm.db from your backup ..."
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo systemctl start kanidm'"
		echo "    sudo -u nix -H ssh nix@$supplier 'sudo kanidmd database verify -c /etc/kanidm/server.toml'  # must be OK"
		echo "    just idm-sync-certs"
		echo "    git add usr/secrets/replication && git commit -m 'fix(idm): resync replication certs'"
		echo "    just apply $supplier,{{consumers}}"
		echo "    # force the first refresh on a consumer if needed:"
		echo "    sudo -u nix -H ssh nix@<consumer> 'sudo kanidmd refresh-replication-consumer -c /etc/kanidm/server.toml'"
	else
		echo "  Certs out of sync. Resync and redeploy:"
		echo
		echo "    just idm-sync-certs"
		echo "    git add usr/secrets/replication && git commit -m 'fix(idm): resync replication certs'"
		echo "    just apply $supplier,{{consumers}}"
	fi
	echo

# `mode`: `normal` (n) the admin sets every access and stores it in the vault,
# the user only chooses a master password; `advanced` (a) the user sets every
# access. `hash`: ready session password hash (advanced, cf. `just passwd`).
# Re-run = reset: an access already set is kept unless confirmed (y/N).
#
# Invite a user or reset their access (Linux, Kanidm, Vaultwarden)
[group('identities')]
invite login mode='normal' hash='':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just invite "{{login}}" "{{mode}}" '{{hash}}'
	login="{{login}}"
	case "{{mode}}" in
		normal|n) mode=normal ; ttl=3600 ;;
		advanced|a) mode=advanced ; ttl=86400 ;;
		*) just _fail "Unknown mode '{{mode}}': normal (n) or advanced (a)." ;;
	esac
	[ -z '{{hash}}' ] || [ "$mode" = advanced ] || just _fail "A hash is for the advanced mode only."
	[ -f {{sopsSecretsFile}} ] || just _fail "No sops secrets file: run 'just configure-admin-host' first."
	export SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}}
	secret() { sops -d --extract "$1" {{sopsSecretsFile}} ; }
	ask() { local a ; read -r -p "$1 (y/N) " a ; [[ $a =~ ^[yY]$ ]] ; }
	jar='' ; trap 'rm -f "$jar"' EXIT

	#--------------------------------------------------------------------------
	# 0. Checks and current state: nothing is written before confirmation
	#--------------------------------------------------------------------------

	info=$(just _account-info "$login")
	[ "$info" != null ] || just _fail "Unknown user '$login': declare it in etc/config.yaml, then 'just clean'."
	get() { jq -r ".$1 // \"\"" <<< "$info" ; }
	name=$(get name) ; email=$(get email) ; idmhost=$(get idmHost) ; vault=$(get vault)
	hosts=$(jq -r '.hosts | join(", ")' <<< "$info")
	[ -n "$email" ] || just _fail "No email for '$login' in etc/config.yaml."
	[ -n "$idmhost" ] || just _fail "No idm service declared in etc/config.yaml."
	just _log "Reading the current state of $login..." "INVITE"

	# Kanidm: the account comes from the HCS deployment, never from here.
	person=$(just _kanidm "$idmhost" person get "$login")
	grep -qx "name: $login" <<< "$person" \
		|| just _fail "No Kanidm account '$login': deploy it first ('just apply $idmhost')."
	kcreds=$(just _kanidm "$idmhost" person credential status "$login" | sed '/^---$/d;/^$/d')

	# Linux: an account attached to at least one host.
	linuxset=no
	if [ -n "$hosts" ] && secret "[\"user\"][\"$login\"][\"password-hash\"]" >/dev/null 2>&1 ;then
		linuxset=yes
	fi

	# Vaultwarden: the admin API only accepts its session cookie. Own User-Agent:
	# the proxy noise filter rejects `curl` (cf. `badBotsSection`).
	vaultstate=none
	vwcurl() { curl -A 'DNF just invite' "$@" ; }
	if [ -n "$vault" ] ;then
		jar=$(mktemp)

		# An Argon2 hash in sops (admin choice) leaves only the admin to know
		# the token: ask for it.
		token=$(secret '["vaultwarden-admin-token"]')
		if [[ $token == \$argon2* ]] ;then
			read -r -s -p "Vaultwarden admin token: " token ; echo >&2
		fi
		printf '%s' "$token" \
			| vwcurl -fsS -o /dev/null -c "$jar" --data-urlencode 'token@-' "$vault/admin" \
			|| just _fail "Vaultwarden admin login refused ($vault/admin)."
		unset token
		code=$(vwcurl -sS -o /dev/null -w '%{http_code}' -b "$jar" \
			"$vault/admin/users/by-mail/$(jq -rn --arg e "$email" '$e | @uri')")
		case "$code" in
			200) vaultstate=exists ;;
			404) vaultstate=absent ;;
			*) just _fail "Vaultwarden account lookup failed (HTTP $code)." ;;
		esac
	fi

	# Summary and plan, confirmed once.
	just _log "$login ($name, $email), mode $mode" "INVITE"
	if [ -z "$hosts" ] ;then
		echo "  - Linux session: no host, services account"
	elif [ "$linuxset" = no ] ;then
		echo "  - Linux session ($hosts): password to set"
	else
		echo "  - Linux session ($hosts): password set, reset asked"
	fi
	if [ -z "$kcreds" ] ;then
		echo "  - Kanidm: no password set, reset link valid $((ttl / 3600)) h"
	else
		echo "  - Kanidm: password set, new reset link asked"
	fi
	case "$vaultstate/$mode" in
		none/*) echo "  - Vault: no vaultwarden service" ;;
		exists/*) echo "  - Vault: account exists, kept" ;;
		absent/advanced) echo "  - Vault: invitation sent by the admin API" ;;
		absent/normal) echo "  - Vault: organization invitation, by hand (checklist)" ;;
	esac
	echo "  - Welcome sheet to copy / paste"
	ask "Continue?" || exit 0

	#--------------------------------------------------------------------------
	# 1. Linux session password
	#--------------------------------------------------------------------------

	passwd=no
	if [ -n "$hosts" ] && { [ "$linuxset" = no ] || ask "Reset the Linux session password?" ; } ;then
		if [ "$mode" = advanced ] && [ -z '{{hash}}' ] ;then
			just _info "Hand over the keyboard: $login types their own password." "INVITE"
		fi
		just passwd "$login" '{{hash}}'
		passwd=yes
	fi

	#--------------------------------------------------------------------------
	# 2. Kanidm reset link
	#--------------------------------------------------------------------------

	link='' ; expiry=''
	if [ -z "$kcreds" ] || ask "Create a new Kanidm reset link?" ;then
		res=$(just _idm-reset-link "$idmhost" "$login" "$ttl")
		link=$(sed -n 1p <<< "$res")
		expiry=$(sed -n 2p <<< "$res")
	fi

	#--------------------------------------------------------------------------
	# 3. Vaultwarden invitation (advanced; normal goes through the organization)
	#--------------------------------------------------------------------------

	if [ "$vaultstate/$mode" = absent/advanced ] ;then
		vwcurl -fsS -o /dev/null -b "$jar" -H 'Content-Type: application/json' \
			--data "$(jq -cn --arg e "$email" '{email: $e}')" "$vault/admin/invite" \
			|| just _fail "Vaultwarden invitation failed."
		just _log "Vaultwarden invitation sent to $email." "INVITE"
	fi

	#--------------------------------------------------------------------------
	# 4. Welcome sheet: plain markdown bullets, in the network locale
	#--------------------------------------------------------------------------

	case "$(get locale)" in
		fr*)
			hello="Bonjour ${name:-$login},"
			intro="Voici vos accès au réseau :"
			f_login="Identifiant" ; f_vault="Coffre-fort" ; f_idm="Identité (connexion unique)"
			f_element="Messagerie (bouton IDM)" ; f_home="Accueil"
			steps="Pour commencer :"
			s_vault_new="Ouvrez l'e-mail d'invitation du coffre-fort et choisissez votre mot de passe principal : c'est le seul à retenir."
			s_vault_adv="Ouvrez l'e-mail d'invitation du coffre-fort : créez votre coffre et activez sa double authentification (2FA)."
			s_items="Tous vos autres accès sont rangés dans votre coffre-fort."
			s_linux="Session Linux : mot de passe remis par votre administrateur."
			s_link="Définissez votre identité (mot de passe, TOTP, clés d'accès) avant le"
			s_bw="Installez Bitwarden (navigateur, smartphone) : à la connexion, choisissez « auto-hébergé » et saisissez l'adresse du coffre-fort."
			s_urgent="Conseillé : dans le coffre, Paramètres > Accès d'urgence, désignez un contact de confiance."
			todo="À faire (administrateur) :"
			t_coll="Coffre : créer la collection $login dans l'organisation"
			t_linux="Session Linux : ranger le mot de passe dans la collection"
			t_link="Identité : définir mot de passe et TOTP, les ranger dans la collection, lien valable jusqu'au"
			t_invite="Inviter $email dans l'organisation, accès en écriture à la collection"
			t_confirm="Confirmer le membre une fois son coffre créé"
			t_urgent="Accès d'urgence : se faire désigner contact de confiance (Prise de contrôle)"
			datefmt='%d/%m/%Y à %H:%M' ; sep=' : '
			;;
		*)
			hello="Hello ${name:-$login},"
			intro="Here are your accesses to the network:"
			f_login="Login" ; f_vault="Password vault" ; f_idm="Identity (single sign-on)"
			f_element="Messaging (IDM button)" ; f_home="Home page"
			steps="Getting started:"
			s_vault_new="Open the vault invitation e-mail and choose your master password: the only one to remember."
			s_vault_adv="Open the vault invitation e-mail: create your vault and enable its two-step login (2FA)."
			s_items="All your other accesses are stored in your vault."
			s_linux="Linux session: password handed over by your administrator."
			s_link="Set your identity (password, TOTP, passkeys) before"
			s_bw="Install Bitwarden (browser, smartphone): at login, choose \"self-hosted\" and enter the vault address."
			s_urgent="Advised: in the vault, Settings > Emergency access, name a trusted contact."
			todo="To do (administrator):"
			t_coll="Vault: create the collection $login in the organization"
			t_linux="Linux session: store the password in the collection"
			t_link="Identity: set password and TOTP, store them in the collection, link valid until"
			t_invite="Invite $email into the organization, write access to the collection"
			t_confirm="Confirm the member once their vault is created"
			t_urgent="Emergency access: become their trusted contact (Takeover)"
			datefmt='%Y-%m-%d %H:%M' ; sep=': '
			;;
	esac
	[ -z "$expiry" ] || expiry=$(date -d "$expiry" "+$datefmt")

	just _log "Welcome sheet (copy / paste):" "INVITE"
	echo "-----"
	echo "$hello"
	echo
	echo "$intro"
	echo
	echo "- $f_login$sep$login"
	echo "- E-mail$sep$email"
	[ -z "$vault" ] || echo "- $f_vault$sep$vault"
	echo "- $f_idm$sep$(get idm)"
	[ -z "$(get element)" ] || echo "- $f_element$sep$(get element)"
	[ -z "$(get homepage)" ] || echo "- $f_home$sep$(get homepage)"
	echo
	echo "$steps"
	echo
	if [ "$mode" = normal ] ;then
		[ "$vaultstate" != absent ] || echo "- $s_vault_new"
		[ "$vaultstate" = none ] || echo "- $s_items"
		[ -z "$hosts" ] || echo "- $s_linux"
	else
		[ "$vaultstate" != absent ] || echo "- $s_vault_adv"
		[ -z "$link" ] || echo "- $s_link $expiry$sep$link"
		[ "$vaultstate" = none ] || echo "- $s_urgent"
	fi
	[ "$vaultstate" = none ] || echo "- $s_bw"
	echo "-----"

	# Advanced: the link goes to the user, the QR code is for the screen.
	if [ "$mode" = advanced ] && [ -n "$link" ] ;then
		just _log "Identity link QR code (to scan):" "INVITE"
		printf '%s' "$link" | {{nix}} shell nixpkgs#qrencode --command qrencode -t UTF8
	fi

	# Normal: what only the admin can do, in the vault web UI.
	if [ "$mode" = normal ] ;then
		just _log "$todo" "INVITE"
		[ "$vaultstate" != absent ] || echo "- [ ] $t_coll"
		[ "$passwd" = no ] || echo "- [ ] $t_linux"
		[ -z "$link" ] || echo "- [ ] $t_link $expiry$sep$link"
		if [ "$vaultstate" = absent ] ;then
			echo "- [ ] $t_invite"
			echo "- [ ] $t_confirm"
			echo "- [ ] $t_urgent"
		fi
	fi

	#--------------------------------------------------------------------------
	# 5. Next steps
	#--------------------------------------------------------------------------

	if [ "$passwd" = yes ] ;then
		just _info "Commit usr/secrets, then deploy: just apply @user-$login" "INVITE"
	fi
	just _info "Optional YubiKey: just yubikey $login" "INVITE"
