# Kanidm (identity manager) DNF Service.

{
  lib,
  dnfLib,
  network,
  host,
  hosts,
  zone,
  config,
  users,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.darkone.service.idm;
  srvPort = 8443;
  inherit (config.sops) secrets;
  isHcs = dnfLib.isHcs host zone network;
  isMainReplica = isHcs || !network.coordination.enable;

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

  defaultParams = {
    title = "Authentification";
    description = "Global authentication for DNF services";
    ip = "127.0.0.1";
    icon = "kanidm";
  };
  params = dnfLib.extractServiceParams host network "idm" defaultParams;

  # OAuth2 client expansion: cross-product of registered templates with the
  # service instances declared in `network.services`. Each raw pair captures
  # ONE (template, instance) tuple; they are then grouped by `clientId` to
  # produce one provisioned kanidm client per logical service (multi-zone
  # services share a single client with a merged `originUrl` list).
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
        svcHost = dnfLib.findHost svc.host svc.zone hosts;
        svcRegistration = config.darkone.system.services.service.${svc.name} or { };
        svcDflts = svcRegistration.defaultParams or { };
        svcParams = dnfLib.buildServiceParams svcHost network svc svcDflts;
        clientId = dnfLib.oauth2ClientName {
          inherit (svc) name;
          inherit (tpl) clientName;
        } svcParams;
      in
      [
        {
          inherit clientId tpl;
          params = svcParams;
          secret = "oidc-secret-${clientId}";
        }
      ]
  ) network.services;

  # Logical OAuth2 clients to provision. Each entry merges all raw pairs
  # sharing the same `clientId`: `originUrls` is the union of redirect URIs
  # (typed as a list by kanidm-provision), `originLanding` is the landing of
  # the first instance (typed as a scalar). See `dnfLib.mkOauth2Clients`.
  oauth2Clients = dnfLib.mkOauth2Clients rawPairs;
in
{
  options = {
    darkone.service.idm.enable = mkEnableOption "Enable local SSO with Kanidm";

    # OAuth2 client registry. Each service module that supports OIDC contributes
    # a template here unconditionally; when the idm module is enabled, kanidm
    # iterates `network.services` and provisions one client per (template,
    # instance) pair (see the expansion in the `config` block below).
    #
    # Service modules declare path templates only (no scheme/host); idm.nix
    # prefixes them with the resolved `params.href` of each service instance
    # to eliminate hardcoded subdomains.
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

  config = mkMerge [

    #========================================================================
    # DNF Service configuration
    #========================================================================

    {
      darkone.system.services.service.idm = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/kanidm" ];
        proxy.enable = isMainReplica;
        proxy.servicePort = srvPort;
        proxy.scheme = "https";
        proxy.extraConfig = ''
          {
            transport http {
              tls_insecure_skip_verify
            }
            header_up Host {host}
          }
        '';
      };
    }

    (mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "idm";

      # SMTP Relay
      darkone.service.postfix.enable = true;

      #========================================================================
      # Kanidm user & secrets
      #========================================================================

      # Kanidm internal secrets + OAuth2 client secrets (one per provisioned
      # client, generated from `oauth2Clients`). The `oidc-secret-internal`
      # entry is consumed by oauth2-proxy (in `system/services.nix`), not by
      # kanidm provisioning, hence its presence in the static list.
      sops.secrets = mkMerge [
        (listToAttrs (
          map
            (item: {
              name = item;
              value = {
                mode = "0400";
                owner = "kanidm";
              };
            })
            [
              "kanidm-idm-admin-password"
              "kanidm-admin-password"
              "kanidm-tls-chain"
              "kanidm-tls-key"
              "oidc-secret-internal"
            ]
        ))
        (listToAttrs (
          map (c: {
            name = c.secret;
            value = {
              mode = "0400";
              owner = "kanidm";
            };
          }) oauth2Clients
        ))
      ];

      # Invariant : toutes les instances d'un même clientId pointent vers le
      # même nom de secret (dérivé du clientId par construction). Le bloc
      # ci-dessous documente cet invariant et lèverait une erreur claire si
      # `mkOauth2Clients` venait à changer de stratégie.
      assertions = map (c: {
        assertion = lib.unique (map (i: i.secret) c.instances) == [ c.secret ];
        message = "OAuth2 client '${c.clientId}': secret divergence across instances";
      }) oauth2Clients;

      #========================================================================
      # Kanidm service
      #========================================================================

      systemd.services.kanidmd.serviceConfig = mkIf (!isHcs) {

        # On autorise l'accès en lecture aux chemins système vitaux
        # -> https://github.com/kanidm/kanidm/blob/392a10afbc19759d1431025a2daee0dd903b2733/examples/unixd#L77
        ReadOnlyPaths = [
          "/run/current-system/sw/bin"
          "/etc/profiles/per-user/nix/bin"
          "${pkgs.zsh}/bin"
        ];
      };

      # Sendmail permissions
      systemd.services.kanidm.path = [
        pkgs.postfix
        pkgs.coreutils
      ];

      #========================================================================
      # Kanidm instance
      #========================================================================

      # Kanidm main instance
      services.kanidm = {
        package = pkgs.kanidm_1_9.withSecretProvisioning;

        #----------------------------------------------------------------------
        # SERVER
        #----------------------------------------------------------------------

        # Gère la BD (Argon2id) et expose des interfaces API, Web + pont LDAP en lecture.
        # -> https://github.com/kanidm/kanidm/blob/master/examples/server.toml
        server = {
          enable = true;
          settings = {
            bindaddress = "${params.ip}:${toString srvPort}";

            # The domain that Kanidm manages. Must be below or equal to the domain specified in serverSettings.origin.
            # This can be left at null, only if your instance has the role ReadOnlyReplica.
            inherit (network) domain;

            # The origin of the Kanidm instance.
            origin = params.href;

            # Address and port the LDAP server is bound to. Setting this to null disables the LDAP interface.
            ldapbindaddress = mkIf isMainReplica "${host.vpnIp}:636";

            # The role of this server. This affects the replication relationship and thereby available features.
            # -> N'existe pas dans la conf kanidm...
            role = if isMainReplica then "WriteReplica" else "WriteReplicaNoUI";

            # Internal TLS Certificates
            # openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=127.0.0.1";
            tls_chain = secrets.kanidm-tls-chain.path;
            tls_key = secrets.kanidm-tls-key.path;

            # TODO
            #replication = {};
          };
        };

        #----------------------------------------------------------------------
        # CLIENT
        #----------------------------------------------------------------------

        # Web/CLI client
        client = {
          enable = true;
          settings = {
            uri = params.href;
            connect_timeout = 86400; # 24h (seconds)
          };
        };

        #----------------------------------------------------------------------
        # UNIXD / PAM / NSS (WIP)
        #----------------------------------------------------------------------

        # Configuration du démon Unix pour PAM/NSS (remplace SSSD)
        unix = {
          enable = !isHcs;
          settings = {
            default_shell = "/etc/profiles/per-user/nix/bin/zsh";
            pam_allowed_login_groups = [ "posix" ];
          };
        };

        #----------------------------------------------------------------------
        # Provision
        #----------------------------------------------------------------------

        provision = {
          enable = true;

          # Determines whether deleting an entity in this provisioning config should automatically cause them to be removed from kanidm, too.
          # This works because the provisioning tool tracks all entities it has ever created.
          # If this is set to false, you need to explicitly specify present = false to delete an entity.
          autoRemove = true;
          adminPasswordFile = secrets.kanidm-admin-password.path;
          idmAdminPasswordFile = secrets.kanidm-idm-admin-password.path;
          groups = {
            posix = {
              present = true; # default
              members = mapAttrsToList (name: _: name) users;

              # Optional. Defaults to true if not given.
              # Whether groups should be appended (false) or overwritten (true).
              # In append mode, members of this group can be managed manually in kanidm
              # in addition to members declared here, but removing a member from this state.json
              # will not remove the corresponding member from the group in kanidm! Removals have
              # to be reflected manually!
              overwriteMembers = true;
            };
            users.members = mapAttrsToList (name: _: name) users;
            admins.members = mapAttrsToList (name: _: name) (
              filterAttrs (_: u: any (g: g == "idm-admins") u.groups) users
            );
            devs.members = mapAttrsToList (name: _: name) (
              filterAttrs (_: u: any (g: g == "idm-devs") u.groups) users
            );
          };

          #----------------------------------------------------------------------
          # OAuth2 provisioning
          #----------------------------------------------------------------------
          #
          # Each entry below comes from a `darkone.service.idm.oauth2.<name>`
          # template contributed by a service module, expanded against the
          # matching `network.services` instances and merged by `clientId`.
          # See the `rawPairs` / `oauth2Clients` let-bindings above and the
          # OAuth2 template in `service/forgejo.nix` for the canonical
          # example. Multi-instance services (eg. `monitoring` per zone)
          # produce a single Kanidm client whose `originUrl` lists every
          # zone's redirect URI.
          # -> https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest

          systems.oauth2 = listToAttrs (
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
          );

          #----------------------------------------------------------------------
          # Users provisioning
          #----------------------------------------------------------------------

          # https://github.com/oddlama/kanidm-provision?tab=readme-ov-file#json-schema
          persons = mapAttrs (_: u: {
            present = true; # default
            displayName = u.name;
            legalName = u.name;
            mailAddresses = [ u.email ];
            #enableUnix = false; # Does not exists
            #gidNumber = 100;    # Does not exists
            groups = [ "posix" ];
          }) users;
        };
      };
    })
  ];
}
