# DNF — Kanidm OIDC/OAuth2 wiring
#
# Derives the values needed to connect a DNF service to Kanidm as an OAuth2
# client: stable client identifier, SOPS secret name, Kanidm public URL and
# protocol endpoints, plus the provisioning entries fed to Kanidm. Pure and
# side-effect free.

{
  lib,
  topology,
  serviceParams,
}:
let
  inherit (lib) hasInfix findFirst;
  inherit (topology) findHost;
  inherit (serviceParams) buildServiceParams;

  # Prefix `path` with `href` unless it is already an absolute URI (eg.
  # mobile-app schemes such as `app.immich:///oauth-callback`). Private
  # helper consumed by `mkOauth2Clients`.
  fullUrl = href: path: if hasInfix "://" path then path else "${href}${path}";
in
rec {

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
}
