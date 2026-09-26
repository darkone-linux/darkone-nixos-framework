# DNF just — private identity helpers: account lookup, Kanidm CLI as idm_admin.

# One declared account and the URLs its welcome sheet needs, as JSON (`null`
# for an unknown login). Reads var/generated only: the `nix` user cannot
# evaluate the workspace flake (git ownership of the checkout).
_account-info login:
	#!/usr/bin/env bash
	set -euo pipefail
	[[ "{{login}}" =~ ^[a-z_][a-z0-9_-]*$ ]] || just _fail "Invalid login '{{login}}'."
	{{nix}} eval --json --impure --expr '
	  let
	    login = "{{login}}";
	    users = import {{workDir}}/var/generated/users.nix;
	    hosts = import {{workDir}}/var/generated/hosts.nix;
	    network = import {{workDir}}/var/generated/network.nix;
	    inherit (import {{dnfDir}}/lib/constants.nix) globalZone;
	    user = users.${login} or null;
	    mine = builtins.filter (h: builtins.elem login (h.users or [ ])) hosts;

	    # Home zone: the one of its hosts, else its first `zone-<name>` group.
	    zoneGroups = builtins.filter (g: builtins.substring 0 5 g == "zone-") (user.groups or [ ]);
	    zone =
	      if mine != [ ] then (builtins.head mine).zone
	      else if zoneGroups != [ ] then builtins.substring 5 100 (builtins.head zoneGroups)
	      else null;
	    pick = name: zones:
	      let m = builtins.filter (s: s.name == name && (zones == null || builtins.elem s.zone zones)) network.services;
	      in if m == [ ] then null else builtins.head m;
	    main = name: let g = pick name [ globalZone ]; in if g != null then g else pick name null;

	    # Same rule as `serviceHref` (lib/service-params.nix).
	    href = s:
	      let h = builtins.head (builtins.filter (x: x.hostname == s.host && x.zone == s.zone) hosts);
	      in if s == null then null else
	        (if network.coordination.enable then "https://" else "http://")
	        + (s.domain or s.name) + "." + (if s.global or false then h.networkDomain else h.zoneDomain);
	    idm = main "idm";
	  in
	  if user == null then null else {
	    inherit (user) name email;
	    hosts = map (h: h.hostname) mine;
	    idmHost = if idm == null then null else idm.host;
	    idm = href idm;
	    vault = href (main "vaultwarden");
	    element = href (main "element");
	    homepage = if zone == null then null else href (pick "homepage" [ zone ]);
	    locale =
	      if zone != null && network.zones ? ${zone} then network.zones.${zone}.locale or network.default.locale or ""
	      else network.default.locale or "";
	  }'

# `kanidm <args>` as idm_admin on {{host}}. The password travels from sops to
# the remote KANIDM_PASSWORD through stdin: never in any argv. Run as `nix`.
_kanidm host +args:
	#!/usr/bin/env bash
	set -euo pipefail
	{ SOPS_AGE_KEY_FILE={{sopsInfraKeyFile}} sops -d --extract '["kanidm-idm-admin-password"]' {{sopsSecretsFile}} ; echo ; } \
		| ssh -o BatchMode=yes nix@"{{host}}" \
			'read -r KANIDM_PASSWORD ; export KANIDM_PASSWORD ; kanidm login --name idm_admin >/dev/null && kanidm {{args}} --name idm_admin'

# Kanidm credential reset link of {{login}}, valid {{ttl}} seconds (1 h to
# 24 h). Prints the URL, then its expiry (RFC 3339).
_idm-reset-link host login ttl='3600':
	#!/usr/bin/env bash
	set -euo pipefail
	out=$(just _kanidm "{{host}}" person credential create-reset-token "{{login}}" --ttl "{{ttl}}")
	url=$(sed -n 's/^This link: //p' <<< "$out")
	expiry=$(sed -n 's/^This token will expire at: //p' <<< "$out")
	[ -n "$url" ] || just _fail "No Kanidm reset link for {{login}} (see the output above)."
	printf '%s\n%s\n' "$url" "$expiry"
