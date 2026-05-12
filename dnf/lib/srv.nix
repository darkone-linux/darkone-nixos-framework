# DNF — services helpers
#
# Pure helpers that resolve service-related values (parameters, host
# membership, firewall paths) from the flat data structures coming out of
# `var/generated/` (hosts, network, services). All functions are total and
# free of side effects so they can be reused by any DNF module.

{
  lib,
  strings,
  constants,
}:
let
  inherit (lib)
    hasAttr
    hasAttrByPath
    findFirst
    hasInfix
    ;

  # Prefix `path` with `href` unless it is already an absolute URI (eg.
  # mobile-app schemes such as `app.immich:///oauth-callback`). Private
  # helper consumed by `mkOauth2Clients`.
  fullUrl = href: path: if hasInfix "://" path then path else "${href}${path}";
in
rec {

  # Look up a host by hostname and zone in a list of hosts.
  # Returns `{}` when not found, matching the convention used by the rest
  # of the helpers (callers may then probe with `hasAttr` before access).
  findHost =
    hostname: zoneName: hosts:
    findFirst (h: h.hostname == hostname && h.zone == zoneName) { } hosts;

  # Look up a service by name and zone in a list of services.
  # Returns `null` when not found so callers can branch explicitly.
  findService =
    serviceName: zoneName: services:
    findFirst (s: s.name == serviceName && s.zone == zoneName) null services;

  # Canonical Kanidm OAuth2 client identifier for a service instance.
  #
  # Given the service name (and an optional `clientName` override) plus the
  # resolved `params` (from `buildServiceParams`), return the unique client
  # name used for both Kanidm provisioning and the consumer-side `clientId`.
  #
  # Naming rule:
  #   1. an explicit `clientName` always wins (used to preserve historical
  #      identifiers like "matrix-synapse" or "open-webui"),
  #   2. when the public sub-domain matches the service name, the client is
  #      named after the service (eg. `mealie`, `forgejo`),
  #   3. otherwise the sub-domain disambiguates (eg. `outline-notes`).
  #
  # This keeps the secrets registry (`oidc-secret-${clientId}`) and the
  # Kanidm OpenID issuer URL stable per (service, sub-domain) tuple, which
  # is also the natural unit of unicity in `network.services`.
  oauth2ClientName =
    {
      name,
      clientName ? null,
    }:
    params:
    if clientName != null then
      clientName
    else if params.domain == name then
      name
    else
      "${name}-${params.domain}";

  # Resolve the public URL of the Kanidm (idm) instance reachable from the
  # current network. Looks up the first `idm` entry in `network.services`
  # and returns its computed `href` (eg. `https://idm.example.com`).
  #
  # Returns `null` when no `idm` service is registered, so callers can
  # short-circuit OIDC wiring on hosts where Kanidm is not deployed.
  idmHref =
    network: hosts:
    let
      svc = findFirst (s: s.name == "idm") null network.services;
    in
    if svc == null then
      null
    else
      let
        svcHost = findHost svc.host svc.zone hosts;
      in
      (buildServiceParams svcHost network svc { }).href;

  # Resolve effective service parameters by merging, in order:
  # 1. fields explicitly set on the network service entry,
  # 2. defaults declared by the service module,
  # 3. derived values (FQDN, href, IP) computed from the host topology.
  #
  # Empty strings in defaults are treated as missing so the derived values
  # take over (eg. `domain` falls back to the service name).
  #
  # Used as a building block by `extractServiceParams`.
  buildServiceParams =
    serviceHost: network: service: defaults:
    let
      inherit (service) name;
      ucName = strings.ucFirst name;
      domain =
        if hasAttr "domain" service then
          service.domain
        else if (hasAttr "domain" defaults) && defaults.domain != "" then
          defaults.domain
        else
          name;
      title =
        if hasAttr "title" service then
          service.title
        else if (hasAttr "title" defaults) && defaults.title != "" then
          defaults.title
        else
          ucName;
      description =
        if hasAttr "description" service then
          service.description
        else if (hasAttr "description" defaults) && defaults.description != "" then
          defaults.description
        else
          "${ucName} local service";
      icon =
        "sh-"
        + (
          if hasAttr "icon" service then
            service.icon
          else if (hasAttr "icon" defaults) && defaults.icon != "" then
            defaults.icon
          else
            name
        );
      global =
        if hasAttr "global" service then
          service.global
        else if hasAttr "global" defaults then
          defaults.global
        else
          false;
      noRobots =
        if hasAttr "noRobots" service then
          service.noRobots
        else if hasAttr "noRobots" defaults then
          defaults.noRobots
        else
          true;
      zone = if hasAttr "zone" service then service.zone else serviceHost.zone;
      host = if hasAttr "host" service then service.host else serviceHost.hostname;
      fqdn =
        if global then "${domain}.${serviceHost.networkDomain}" else "${domain}.${serviceHost.zoneDomain}";
      href = (if network.coordination.enable then "https://" else "http://") + fqdn;

      # IP resolution cascade:
      # 1. value explicitly set on the service or its defaults,
      # 2. on the HCS itself, services answer on loopback (127.0.0.1),
      # 3. external host registered in our tailnet -> reach via vpnIp,
      # 4. plain host in a local zone -> reach via host.ip.
      ip =
        if hasAttr "ip" service then
          service.ip
        else if (hasAttr "ip" defaults) && defaults.ip != "" then
          defaults.ip
        else if
          (hasAttrByPath [ "coordination" "hostname" ] network)
          && (serviceHost.hostname == network.coordination.hostname)
        then
          "127.0.0.1"
        else if (hasAttr "vpnIp" serviceHost) && serviceHost.vpnIp != "" then
          serviceHost.vpnIp
        else
          serviceHost.ip;
    in
    {
      inherit domain;
      inherit title;
      inherit description;
      inherit icon;
      inherit global;
      inherit noRobots;
      inherit zone;
      inherit host;
      inherit fqdn;
      inherit href;
      inherit ip;
    };

  # Look up a service entry matching the (host, zone) pair and call
  # `buildServiceParams` on it. When no entry is found, an empty attrset is
  # passed so all values fall back on `defaults` and topology.
  extractServiceParams =
    serviceHost: network: serviceName: defaults:
    let
      overloadParams = findFirst (
        s: s.name == serviceName && s.host == serviceHost.hostname && s.zone == serviceHost.zone
      ) { } network.services;
    in
    buildServiceParams serviceHost network overloadParams defaults;

  # True when `host` has a non-empty `vpnIp` field, ie. when it is
  # registered as a headscale (tailscale) client. The non-empty check
  # avoids classifying a host as VPN client based solely on the attribute
  # being present (the generated data may emit empty strings).
  isVpnClient = host: hasAttr "vpnIp" host && host.vpnIp != "";

  # True when `host` is the gateway of a local zone. A VPN client is never
  # a gateway by construction.
  isGateway =
    host: zone:
    !(isVpnClient host)
    && hasAttrByPath [ "gateway" "hostname" ] zone
    && host.hostname == zone.gateway.hostname;

  # True when `zone` is a local zone (not the global, Internet-facing one).
  inLocalZone = zone: zone.name != constants.globalZone;

  # True when `host` is the headscale coordination server (HCS) of the
  # network. The HCS lives in the global zone and matches the coordination
  # hostname declared at the network level.
  isHcs =
    host: zone: network:
    (!(inLocalZone zone))
    && network.coordination.enable
    && network.coordination.hostname == host.hostname;

  # Path inside `networking.firewall` selecting the internal interface to
  # which a service should be exposed. Returns `[]` for hosts that have no
  # internal interface (eg. external clients without VPN).
  #
  # Usage:
  #   networking.firewall = lib.setAttrByPath
  #     (dnfLib.getInternalInterfaceFwPath host zone)
  #     { allowedTCPPorts = [ port ]; };
  getInternalInterfaceFwPath =
    host: zone:
    if (isGateway host zone) then
      [
        "interfaces"
        constants.lanInterface
      ]
    else
      (
        if (isVpnClient host) then
          [
            "interfaces"
            constants.vpnInterface
          ]
        else
          [ ]
      );

  # Resolve the preferred IP of a host: tailnet IP when registered, plain
  # `ip` otherwise, falling back to loopback when neither is known. Mirrors
  # the cascade used internally by `buildServiceParams` so consumer modules
  # do not have to re-implement it.
  preferredIp =
    host:
    if (hasAttr "vpnIp" host) && host.vpnIp != "" then
      host.vpnIp
    else if (hasAttr "ip" host) && host.ip != "" then
      host.ip
    else
      "127.0.0.1";

  # Firewall fragment opening `ports` on the internal interface of `host`
  # in `zone`. The port list is only effective on non-gateway hosts: on a
  # gateway, traffic flows through the reverse proxy so the service port
  # stays closed on the internal interface.
  #
  # Returns a complete `networking.firewall` fragment ready to assign:
  #
  #   networking.firewall = dnfLib.mkInternalFirewall host zone [ port ];
  mkInternalFirewall =
    host: zone: ports:
    lib.setAttrByPath (getInternalInterfaceFwPath host zone) {
      allowedTCPPorts = lib.mkIf (!(isGateway host zone)) ports;
    };

  # Bundle the three values systematically derived together when wiring a
  # service to Kanidm OIDC: the Kanidm client identifier, the SOPS secret
  # name and the public Kanidm URL. Returns `{ clientId, secret, idmUrl }`
  # with `idmUrl = null` when Kanidm is not deployed on this network.
  #
  # Equivalent to writing by hand:
  #   clientId = dnfLib.oauth2ClientName { name = …; } params;
  #   secret   = "oidc-secret-${clientId}";
  #   idmUrl   = dnfLib.idmHref network hosts;
  mkOidcContext =
    {
      name,
      clientName ? null,
      params,
      network,
      hosts,
    }:
    let
      clientId = oauth2ClientName { inherit name clientName; } params;
    in
    {
      inherit clientId;
      secret = "oidc-secret-${clientId}";
      idmUrl = idmHref network hosts;
    };

  # Group "raw" OAuth2 pairs by `clientId` and produce one provisioning
  # entry per logical client. Multi-instance services (eg. `monitoring`
  # deployed on several zones) share the same Kanidm client but contribute
  # distinct redirect URIs; this helper concatenates and deduplicates them.
  #
  # Input: a list of raw pairs in the shape
  #   { clientId; tpl; params; secret; }
  # where `tpl` must expose `redirectPaths` and `landingPath`, and `params`
  # must expose `href`. Typically built by expanding `network.services`
  # against the registered OAuth2 templates (see `idm.nix`).
  #
  # Output: a list of merged clients
  #   { clientId; tpl; secret; originUrls; originLanding; instances; }
  # with:
  #   - `originUrls`   : union of `${href}${path}` across all instances,
  #                      passing absolute URIs through unchanged,
  #   - `originLanding`: landing of the FIRST instance, because Kanidm's
  #                      `originLanding` is a single string (the portal
  #                      cannot offer several "landing" URLs for one app),
  #   - `instances`    : the raw pairs that fed this client, useful for
  #                      assertions and diagnostics.
  #
  # `tpl` and `secret` are taken from the first instance: all instances of
  # the same `clientId` share the same Kanidm template (the option is keyed
  # by service name in `idm.nix`) and the same secret name (derived from
  # `clientId`), so the choice is invariant.
  mkOauth2Clients =
    rawPairs:
    let
      groups = builtins.groupBy (p: p.clientId) rawPairs;
    in
    lib.mapAttrsToList (
      clientId: pairs:
      let
        head = lib.head pairs;
        originUrls = lib.unique (
          lib.concatMap (p: map (path: fullUrl p.params.href path) p.tpl.redirectPaths) pairs
        );
        originLanding = fullUrl head.params.href head.tpl.landingPath;
      in
      {
        inherit clientId originUrls originLanding;
        inherit (head) tpl secret;
        instances = pairs;
      }
    ) groups;

  # Kanidm OAuth2/OIDC endpoint URLs for a given client. Centralises the
  # protocol-level routes so consumer modules don't hard-code them (and so
  # a Kanidm route change is fixed in one place).
  mkKanidmEndpoints = idmUrl: clientId: {
    authUrl = "${idmUrl}/ui/oauth2";
    tokenUrl = "${idmUrl}/oauth2/token";
    userinfoUrl = "${idmUrl}/oauth2/openid/${clientId}/userinfo";
    jwksUrl = "${idmUrl}/oauth2/openid/${clientId}/public_key.jwk";
    openidConfigUrl = "${idmUrl}/oauth2/openid/${clientId}/.well-known/openid-configuration";
    issuerUrl = "${idmUrl}/oauth2/openid/${clientId}";
  };

  # Activation fragment systematically repeated inside `lib.mkIf cfg.enable`
  # blocks of every DNF service module. Returns the attrset that should be
  # assigned to `darkone.system.services`.
  enableBlock = name: {
    enable = true;
    service.${name}.enable = true;
  };

  # Build the homepage section entries for a list of services. Classifies
  # each entry as public/private and local/remote relative to the current
  # zone, prefixing the description with a colour-coded marker.
  #
  # `currentZoneName` is the zone the consuming host sits in (typically
  # `zone.name` in the caller's scope). Each `srv` must expose
  # `params.{title,description,zone,host,global,href,icon}` and a
  # `displayOnHomepage` flag.
  mkHomepageSection =
    currentZoneName: services:
    map (
      srv:
      let
        pubPriv =
          if srv.params.global then
            (if srv.params.zone == constants.globalZone then "🟢" else "🟡")
          else
            (if srv.params.zone == currentZoneName then "🔵" else "🟠");
        mention = " (" + srv.params.zone + ":" + srv.params.host + ")";
      in
      {
        "${srv.params.title}" = lib.mkIf srv.displayOnHomepage {
          description = srv.params.description + mention + " " + pubPriv;
          inherit (srv.params) href;
          inherit (srv.params) icon;
        };
      }
    ) services;
}
