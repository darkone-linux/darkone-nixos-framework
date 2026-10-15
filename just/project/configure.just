# DNF just — configuration: admin host, new hosts, alert bot.

# Framework installation on local machine (builder / admin)
[group('configure')]
configure-admin-host:
	#!/usr/bin/env bash
	set -euo pipefail

	# Runs as `nix`, the deploy account of a DNF host: on any other machine,
	# sudo would only answer `unknown user nix`.
	if [ "${USER:-}" != "nix" ] && ! getent passwd nix > /dev/null ;then
		just _err "No 'nix' account on this machine: the admin recipes run on a DNF host."
		just _fail "Run this from a host installed with DNF (see the installation guide)."
	fi
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just configure-admin-host

	# Keys, `.sops.yaml` and first secrets: the script `bootstrap-keys` runs on
	# a machine that has no `nix` account yet.
	sudo env "PATH=$PATH" WORKDIR="{{workDir}}" bash {{scriptsDir}}/bootstrap-keys.sh --root /
	if SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} sops -d --extract '["default-password-hash"]' {{sopsSecretsFile}} >/dev/null 2>&1 ;then
		just _info "Default password already set." "SOPS"
	else
		just _log "We need a default password..." "SOPS"
		just passwd-default
	fi

	# Everything the declared services need and nobody has to know: OIDC client
	# secrets, backup credentials, service-to-service tokens... Re-run this
	# recipe after enabling a service to converge the new entries.
	just _gen-secrets
	just _fix_fs_permissions
	just _done

# The first machine of a network has no `nix` account yet: root writes its keys
# under `root` (`/`, or `/mnt` from the installer) with the ids NixOS gives it.
# `hash`: ready crypt hash of `login` (`mkpasswd`), single-quoted: it has `$`.
#
# Create the admin keys and the sops skeleton, no nix account needed
[group('configure')]
bootstrap-keys root='/' login='' hash='':
	#!/usr/bin/env bash
	set -euo pipefail
	args=(--root "{{root}}")
	if [ -n "{{login}}" ] ;then
		args+=(--password-hash "{{login}}" '{{hash}}')
	fi
	sudo env "PATH=$PATH" WORKDIR="{{workDir}}" bash {{scriptsDir}}/bootstrap-keys.sh "${args[@]}"
	just _log "Commit usr/secrets/ before building: flakes only see tracked files." "SOPS"

# Auto-switching here means the chained `copy-id` / `copy-hw` / `push-key`
# already inherit the nix user — their own guards short-circuit cleanly.
#
# `ip`: network address to reach the node ('auto' = resolved by `_target`).
# Configuring a host that sits outside its own zone also installs the ssh
# redirection, so the `apply` that follows reaches it instead of its home
# address; `just roaming-clear {{host}}` drops it once the host is back home.
#
# New host: ssh cp id, extr. hw, push infra key, tailnet enroll, clean, info
[group('configure')]
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

	# No-op without Tailscale or once enrolled. An unreachable HCS must not
	# abort an install: warn, the recipe re-runs alone.
	just tailnet-enroll "{{host}}" "$t" || just _warn "Tailnet enrollment failed, re-run: just tailnet-enroll {{host}}"

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
	just _log "git add . && git commit -m 'Configuring new host {{host}}'"
	just _log "just apply-verbose {{host}}"
	just host-info "{{host}}" "$t"

# The key travels from the HCS to the host through a pipe only: never in argv,
# a variable, the sudo I/O logs or on disk. The HCS mints it for the declared
# tags of the host, whatever the caller asks. Idempotent: a node holding its
# declared name and tags is left alone, a wrong tag or name is fixed in place,
# the offline registration a reinstall left behind is replaced.
#
# Enroll a host in the tailnet (single-use tagged key, idempotent)
[group('configure')]
tailnet-enroll host ip='auto':
	#!/usr/bin/env bash
	set -euo pipefail
	[ "${USER:-}" = "nix" ] || exec sudo -u nix just tailnet-enroll "{{host}}" "{{ip}}"
	cfg={{workDir}}/etc/config.yaml
	if [ "$(yq -r '.network.coordination.enable // false' "$cfg")" != "true" ] ;then
		just _info "No coordination server, nothing to enroll." "TAILNET"
		exit 0
	fi
	hcs=$(yq -r '.network.coordination.hostname' "$cfg")
	enroll=/run/current-system/sw/bin/dnf-tailnet-enroll
	join=/run/current-system/sw/bin/dnf-tailnet-join
	t=$(just _resolve "{{host}}" "{{ip}}")
	on() { ssh -o BatchMode=yes -o ConnectTimeout=15 "nix@$1" "${@:2}" ; }

	# Status needs no root. Exit 3 means no client; anything else, ssh's own
	# 255 included, leaves the state unknown.
	rc=0
	self=$(on "$t" 'command -v tailscale >/dev/null || exit 3; tailscale status --json --peers=false') || rc=$?
	case $rc in
		0) ;;
		3) just _info "{{host}} runs no Tailscale client, nothing to enroll." "TAILNET" ; exit 0 ;;
		*) just _fail "{{host}} at $t: Tailscale status unreadable, ssh or tailscaled down." ;;
	esac
	state=$(jq -r '.BackendState' <<<"$self")
	nodeKey=$(jq -r '.Self.PublicKey // ""' <<<"$self")
	status=$(on "$hcs" sudo "$enroll" status "{{host}}" "$nodeKey")
	want=$(jq -c '.declared' <<<"$status")
	[ "$want" != null ] || just _fail "{{host}}: no declared tailnet identity on $hcs (no tag, or $hcs not deployed since)."

	# Enrolled: headscale knows the node key and the host still holds its login.
	if [ "$(jq -r '.node != null' <<<"$status")" = true ] && [[ $state =~ ^(Running|Stopped|Starting)$ ]] ;then
		just _info "{{host}} already enrolled, backend $state." "TAILNET"
	else
		just _log "{{host}} not enrolled, backend $state: sending a single-use key..." "TAILNET"
		self=$(on "$hcs" sudo "$enroll" key "{{host}}" | on "$t" sudo "$join") \
			|| just _fail "{{host}}: enrollment failed, see above."
		state=$(jq -r '.state' <<<"$self")
		nodeKey=$(jq -r '.nodeKey // ""' <<<"$self")
		[[ $state =~ ^(Running|Stopped)$ ]] \
			|| just _fail "{{host}}: registration failed, backend $state. See journalctl -u tailscaled-autoconnect on {{host}}."
	fi
	node=$(on "$hcs" sudo "$enroll" adopt "{{host}}" "$nodeKey")

	# `adopt` converges; check its outcome rather than trust it.
	summary=$(jq -r '"\(.name) \(.tags | join(",")) \(.ipv4)"' <<<"$node")
	[ "$(jq -r '.name' <<<"$node")" = "{{host}}" ] && [ "$(jq -c '.tags' <<<"$node")" = "$(jq -c '.tags' <<<"$want")" ] \
		|| just _fail "{{host}}: node $summary does not match its declared identity."
	ip=$(jq -r '.ipv4 // ""' <<<"$node")
	declaredIp=$(jq -r '.ipv4 // ""' <<<"$want")
	if [ -n "$declaredIp" ] && [ "$ip" != "$declaredIp" ] ;then
		just _warn "{{host}}: tailnet IP $ip, declared $declaredIp: update etc/config.yaml."
	fi
	just _info "{{host}}: $summary" "TAILNET"

# Send one message to an alert room, body on stdin (markdown). Transport only:
# rooms and token stay here, the caller owns the text. Exit `10` not configured,
# `11` refused by the homeserver (contract with `fleet-update --send-report`).
#
# Send a message to a Matrix alert room (body on stdin)
[group('configure')]
send-msg room:
	#!/usr/bin/env bash
	set -euo pipefail
	WORKDIR="{{workDir}}" bash {{scriptsDir}}/send-msg.sh {{room}}

# Provision the Matrix alert bot + rooms (idempotent) from network.matrix.
# Reads config.yaml (network.matrix.{admin,bot}), creates/refreshes the bot,
# webhook secret and the warnings/incidents rooms, and writes the resulting
# room IDs back into config.yaml. Re-run any time; it only fixes what's missing.
#
# Provision the Matrix alert bot and its rooms (idempotent)
[group('configure')]
configure-alert-bot:
	#!/usr/bin/env bash
	set -euo pipefail
	WORKDIR="{{workDir}}" bash {{scriptsDir}}/configure-alert-bot.sh
	just _fix_fs_permissions
