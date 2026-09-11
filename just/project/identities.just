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
