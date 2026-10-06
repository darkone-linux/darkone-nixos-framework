# DNF — Kanidm OIDC/OAuth2 wiring
#
# Derives the values needed to connect a DNF service to Kanidm as an OAuth2
# client: stable client identifier, SOPS secret name, Kanidm public URL and
# protocol endpoints, plus the provisioning entries fed to Kanidm. Pure and
# side-effect free.

{ lib, serviceParams }:
let
  inherit (lib) hasInfix;
  inherit (serviceParams) serviceHref;

  # `path` prefixed with `href`, unless already an absolute URI (mobile-app
  # schemes such as `app.immich:///oauth-callback`).
  fullUrl = href: path: if hasInfix "://" path then path else "${href}${path}";
in
rec {

  # Kanidm OAuth2 client id of a service instance, stable per (service,
  # sub-domain): an explicit `clientName` (historical ids such as
  # `matrix-synapse`), else the service name when the sub-domain matches it,
  # else `<name>-<domain>` (e.g. `outline-notes`).
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

  # Public Kanidm URL (e.g. `https://idm.example.com`), `null` when no `idm`
  # service is deployed.
  idmHref =
    network: hosts:
    serviceHref {
      name = "idm";
      inherit network hosts;
    };

  # `{ clientId; secret; idmUrl; }` wiring a service to Kanidm OIDC: client
  # id, its sops secret name, Kanidm URL (`null` when Kanidm is absent).
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

  # One Kanidm client per `clientId` out of `{ clientId; tpl; params; secret; }`
  # pairs (cf. `idm.nix`): instances of a multi-zone service share it.
  # - `originUrls`: every instance's redirect URIs, deduplicated;
  # - `originLanding`, `tpl`, `secret`: from the first instance (Kanidm takes
  #   a single landing URL; template and secret derive from the client id);
  # - `instances`: the input pairs, for assertions.
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

  # Kanidm OAuth2/OIDC endpoint URLs of a client, in one place.
  mkKanidmEndpoints = idmUrl: clientId: {
    authUrl = "${idmUrl}/ui/oauth2";
    tokenUrl = "${idmUrl}/oauth2/token";
    userinfoUrl = "${idmUrl}/oauth2/openid/${clientId}/userinfo";
    jwksUrl = "${idmUrl}/oauth2/openid/${clientId}/public_key.jwk";
    openidConfigUrl = "${idmUrl}/oauth2/openid/${clientId}/.well-known/openid-configuration";
    issuerUrl = "${idmUrl}/oauth2/openid/${clientId}";
  };
}
