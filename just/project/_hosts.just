# DNF just — private host helpers: config lookup, address resolution, ssh waits.

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

# The addresses of {{host}} seen from here, one per line: the fixed address of
# its own zone, then the one the local zone reserves for it. Empty when unknown.
#
# The local zone is the one whose gateway actually routes this machine, NOT the
# zone it is declared in — an admin laptop is precisely the thing that moves.
# Declaration is only the fallback (deploying over the VPN, gateway itself).
_zone-addrs host:
	#!/usr/bin/env bash
	set -euo pipefail
	gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)
	{{nix}} eval --raw --impure --expr '
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
	'

# Address to reach {{host}} from the machine running just.
#
# Its own name when both sit in the same zone. Otherwise the address the local
# zone reserves for it: every gateway holds a DHCP reservation for each known
# fleet MAC that is not native to its zone (`zone.roaming`, generated), so a
# machine plugged anywhere is predictable before it has even booted.
#
# Falls back to the host name when nothing matches: a host with no declared MAC
# is simply not reachable outside its zone.
#
# A reservation is an expectation, not evidence, so the roaming address is
# probed before being returned — see the comment on the probe below.
_target host:
	#!/usr/bin/env bash
	set -euo pipefail

	# A zone never reserves an address for its own hosts (the generator skips
	# the home zone): no reservation means same zone, or an unknown host.
	addr=$(just _zone-addrs "{{host}}" | sed -n 2p)
	addr=${addr:-{{host}}}

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
	addrs=()
	case "{{ip}}" in
		''|auto) ;;
		*) addrs+=("{{ip}}") ;;
	esac

	mapfile -t derived < <(just _zone-addrs "{{host}}")
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

# List all colmena hive node names (the deploy source of truth), one per line.
_hive-nodes:
	#!/usr/bin/env bash
	set -euo pipefail
	colmena eval --config {{workDir}}/flake.nix -E '{ nodes, ... }: builtins.attrNames nodes' 2>/dev/null \
		| grep -oE '"[^"]+"' | tr -d '"'
