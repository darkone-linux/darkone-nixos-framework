# DNF idm: Kanidm provisioning (OAuth2 clients, groups, persons).
#
# Every OIDC-capable service module contributes a client template to
# `darkone.service.idm.oauth2`; one client is provisioned per (template,
# instance), merged by `clientId` across zones. Never on a replication
# consumer: it mirrors the HCS.

{
  lib,
  dnfLib,
  network,
  config,
  users,
  ...
}:
let
  inherit (lib)
    any
    concatMap
    filter
    filterAttrs
    listToAttrs
    mapAttrs
    mapAttrsToList
    mkIf
    mkOption
    optionalAttrs
    types
    ;
  cfg = config.darkone.service.idm;
  inherit (cfg.replication) isReplConsumer;
  inherit (config.sops) secrets;

  # Network services resolved by the registry (`system/services.nix`).
  inherit (config.darkone.system.services.resolved) services;

  # https://kanidm.github.io/kanidm/stable/integrations/oauth2.html#configuration
  scopeMaps = rec {
    users = [
      "openid"
      "email"
      "profile"
      "groups"
    ];
    admins = users;
    posix = users;
    devs = users;
  };

  # One (template, service instance) pair per template matching a resolved
  # service; grouped by `clientId` below, so a multi-zone service shares one
  # kanidm client.
  oauth2Templates = config.darkone.service.idm.oauth2;
  rawPairs = concatMap (
    svc:
    let
      tpl = oauth2Templates.${svc.name} or null;
    in
    if tpl == null || !tpl.enable then
      [ ]
    else
      let
        clientId = dnfLib.oauth2ClientName {
          inherit (svc) name;
          inherit (tpl) clientName;
        } svc.params;
      in
      [
        {
          inherit clientId tpl;
          inherit (svc) params;
          secret = "oidc-secret-${clientId}";
        }
      ]
  ) services;

  # Logical OAuth2 clients to provision. Each entry merges all raw pairs
  # sharing the same `clientId`: `originUrls` is the union of redirect URIs
  # (typed as a list by kanidm-provision), `originLanding` is the landing of
  # the first instance (typed as a scalar). See `dnfLib.mkOauth2Clients`.
  oauth2Clients = dnfLib.mkOauth2Clients rawPairs;

  # Forward-auth client of every zone's oauth2-proxy
  # (`system/services/oauth2-proxy.nix`): one callback per homepage instance,
  # the zone auth anchor.
  authCallbackUrls = lib.unique (
    map (svc: "${svc.params.href}/oauth2/callback") (filter (svc: svc.name == "homepage") services)
  );
in
{
  options = {

    # OAuth2 client registry: every OIDC-capable service module contributes a
    # template, unconditionally. Kanidm provisions one client per (template,
    # instance of `network.services`), prefixing the template paths with each
    # instance's resolved `params.href`.
    darkone.service.idm.oauth2 = mkOption {
      default = { };
      description = ''
        OAuth2/OIDC client templates contributed by service modules.
        Kanidm provisions one client per matching entry in `network.services`,
        with `clientId = dnfLib.oauth2ClientName`.
      '';
      type = types.attrsOf (
        types.submodule (_: {
          options = {

            # Disable the template without unloading the consumer module.
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Whether to provision OAuth2 clients for this template.";
            };

            # Override the auto-derived client name. Use this only when an
            # historical identifier must be preserved (eg. "matrix-synapse",
            # "open-webui", "lasuite-docs").
            clientName = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Override the kanidm client name. Defaults to dnfLib.oauth2ClientName.";
            };

            displayName = mkOption {
              type = types.str;
              description = "Human-readable name shown on the kanidm consent screen.";
            };

            imageFile = mkOption {
              type = types.path;
              description = "Application icon. Re-uploaded on every kanidm-provision run.";
            };

            # Path components only (eg. `/oauth/callback`). idm.nix expands
            # them per instance with `${params.href}${path}`.
            redirectPaths = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = "OAuth2 redirect paths (one per accepted callback URL).";
            };

            landingPath = mkOption {
              type = types.str;
              default = "/";
              description = "Auto-connect entry point path on the service.";
            };

            enableLegacyCrypto = mkOption {
              type = types.bool;
              default = false;
              description = "Allow legacy JWT signing algorithms (eg. RS256).";
            };

            allowInsecureClientDisablePkce = mkOption {
              type = types.bool;
              default = false;
              description = "Disable PKCE on the client (only for clients that do not implement it).";
            };

            preferShortUsername = mkOption {
              type = types.nullOr types.bool;
              default = null;
              description = "Use the short username (no domain) in the `preferred_username` claim.";
            };

            # Future home for service-specific extras: `claimMaps`,
            # `scopeMaps` overrides, etc. Merged verbatim into the
            # generated kanidm provision attrset.
            extra = mkOption {
              type = types.attrs;
              default = { };
              description = "Extra attributes merged into the provisioned client (claimMaps, etc).";
            };
          };
        })
      );
    };
  };

  config = mkIf cfg.enable {

    # One secret per provisioned OAuth2 client.
    sops.secrets = listToAttrs (
      map (c: {
        name = c.secret;
        value = {
          mode = "0400";
          owner = "kanidm";
        };
      }) oauth2Clients
    );

    # Invariant: every instance of a clientId shares its secret name (derived
    # from the clientId); fails loudly if `mkOauth2Clients` changes strategy.
    assertions = map (c: {
      assertion = lib.unique (map (i: i.secret) c.instances) == [ c.secret ];
      message = "OAuth2 client '${c.clientId}': secret divergence across instances";
    }) oauth2Clients;

    services.kanidm.provision = {

      # Writes to the database: never on a replication consumer, which gets its
      # whole state from the HCS supplier.
      enable = !isReplConsumer;

      # An entity dropped here is removed from kanidm: the tool tracks what it
      # created (`false` would need an explicit `present = false`).
      autoRemove = true;
      adminPasswordFile = secrets.kanidm-admin-password.path;
      idmAdminPasswordFile = secrets.kanidm-idm-admin-password.path;
      groups = {
        posix = {
          present = true; # default
          members = mapAttrsToList (name: _: name) users;

          # Declared members only. Append mode (`false`) would keep manual
          # additions, and a member removed here would stay in kanidm.
          overwriteMembers = true;
        };
        users.members = mapAttrsToList (name: _: name) users;
        admins.members = mapAttrsToList (name: _: name) (
          filterAttrs (_: u: any (g: g == "idm-admins") u.groups) users
        );
        devs.members = mapAttrsToList (name: _: name) (
          filterAttrs (_: u: any (g: g == "idm-devs") u.groups) users
        );
      }

      # Logins allowed to register a personal device on the tailnet: the
      # headscale OAuth2 client maps its scopes to this group only.
      // optionalAttrs network.coordination.enable { tailnet.members = dnfLib.tailnetUsers users; };

      #----------------------------------------------------------------------
      # OAuth2 provisioning
      #----------------------------------------------------------------------

      # `darkone.service.idm.oauth2.<name>` templates expanded against
      # `network.services`, merged by `clientId` (`rawPairs`/`oauth2Clients`
      # above; canonical template: `service/forgejo.nix`). A multi-zone
      # service gets one client listing every zone's redirect URI.

      systems.oauth2 =
        listToAttrs (
          map (c: {
            name = c.clientId;
            value = {
              inherit (c.tpl)
                displayName
                imageFile
                enableLegacyCrypto
                allowInsecureClientDisablePkce
                ;
              originUrl = c.originUrls;
              inherit (c) originLanding;
              basicSecretFile = config.sops.secrets.${c.secret}.path;
              inherit scopeMaps;
            }
            // optionalAttrs (c.tpl.preferShortUsername != null) { inherit (c.tpl) preferShortUsername; }
            // c.tpl.extra;
          }) oauth2Clients
        )

        # Static client backing oauth2-proxy forward auth. Not derived from a
        # service template: it guards arbitrary reverse-proxy vhosts, with the
        # group policy enforced per-service by Caddy (allowed_groups query).
        // {
          internal-service = {
            displayName = "DNF protected services";
            originUrl = authCallbackUrls;
            originLanding = "https://idm.${network.domain}";
            basicSecretFile = config.sops.secrets.oidc-secret-internal.path;
            inherit scopeMaps;
          };
        };

      #----------------------------------------------------------------------
      # Users provisioning
      #----------------------------------------------------------------------

      # https://github.com/oddlama/kanidm-provision?tab=readme-ov-file#json-schema
      persons = mapAttrs (_: u: {
        present = true; # default
        displayName = u.name;
        legalName = u.name;
        mailAddresses = [ u.email ];
        groups = [ "posix" ];
      }) users;
    };
  };
}
