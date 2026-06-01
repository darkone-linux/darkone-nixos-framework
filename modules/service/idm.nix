# Kanidm (identity manager) DNF Service.

{
  lib,
  dnfLib,
  dnfConfig,
  network,
  host,
  hosts,
  zone,
  config,
  users,
  pkgs,
  workDir,
  ...
}:
with lib;
let
  cfg = config.darkone.service.idm;
  srvPort = 8443;
  inherit (config.sops) secrets;
  isHcs = dnfLib.isHcs host zone network;
  isMainReplica = isHcs || !network.coordination.enable;

  #--------------------------------------------------------------------------
  # Multi-zone read-only replication (automatic, derived from declared services)
  #--------------------------------------------------------------------------
  #
  # No manual flag: the mode is inferred from where `idm` is declared (see
  # `network.services`) and from the coordination topology. Three scenarios:
  #   1. idm on the HCS only        -> single instance, no replication.
  #   2. idm on a gateway, no HCS   -> standalone autonomous instance in the zone.
  #   3. idm on the HCS *and* >=1 local-zone gateway -> replication engaged:
  #      the HCS is the supplier (WriteReplica) and each idm gateway a consumer.
  #
  # In scenario 3 the bootstrap is a real two-step deploy:
  #   - step 1 (`just apply`): HCS and gateways both emit their `[replication]`
  #     identity block, so every node generates its certificate at once. The
  #     gateways stay functional WriteReplicaNoUI until their HCS cert is synced.
  #   - step 2 (`just idm-sync-certs` + `just apply`): partner sub-blocks appear
  #     and each gateway flips to ReadOnlyReplica (pull from the HCS).

  # A coordinated local-zone gateway is a read-only replica candidate.
  isZoneReplica =
    dnfLib.isGateway host zone && dnfLib.inLocalZone zone && network.coordination.enable;

  globalZone = dnfLib.constants.globalZone;
  replPort = dnfConfig.network.ports.kanidmReplPort;
  hcsVpnIp = network.zones.${globalZone}.gateway.vpn.ipv4;
  mkReplOrigin = ip: "repl://${ip}:${toString replPort}";
  hcsOrigin = mkReplOrigin hcsVpnIp;

  # Replication identity certificates are PUBLIC and fetched out-of-band by
  # `just idm-sync-certs` into the consumer workspace. A missing file (phase 1,
  # before the peer has generated its identity) simply omits the partner block
  # so the node still boots and emits its own certificate. Newlines/spaces are
  # stripped: the TOML value must be the bare single-line certificate.
  readReplCert =
    hostname:
    let
      f = workDir + "/usr/secrets/replication/${hostname}.pem";
    in
    if builtins.pathExists f then
      builtins.replaceStrings [ "\n" "\r" " " ] [ "" "" "" ] (builtins.readFile f)
    else
      "";

  # HCS (supplier) certificate. Public, synced out-of-band by `just idm-sync-certs`
  # into usr/secrets/replication/. Empty until step 1's certificates are gathered.
  hcsReplCert = readReplCert network.coordination.hostname;

  # Where idm runs on the network. `network.services` mirrors the per-host service
  # declarations (config.yaml -> var/generated/), and the `idm` key drives
  # `darkone.service.idm.enable` (lib/service-activation.nix), so this is the
  # authoritative cross-host view of "which nodes run idm".
  idmInstances = filter (s: s.name == "idm") network.services;

  # idm declared on the HCS itself.
  idmOnHcs = any (s: s.zone == globalZone && s.host == network.coordination.hostname) idmInstances;

  # Local-zone gateways that run idm = replication consumers (need a gateway VPN
  # IP to bind the pull origin). Keyed by zone name.
  replConsumerZones = filterAttrs (
    _: z:
    dnfLib.inLocalZone z
    && hasAttrByPath [ "gateway" "hostname" ] z
    && hasAttrByPath [ "gateway" "vpn" "ipv4" ] z
    && any (s: s.zone == z.name && s.host == z.gateway.hostname) idmInstances
  ) network.zones;

  # Scenario 3 only: replication engages when idm runs on the HCS *and* on at
  # least one local gateway, on a coordinated network. Scenarios 1 & 2 leave
  # every binding below collapsed to the single-instance behaviour.
  replicationActive = network.coordination.enable && idmOnHcs && replConsumerZones != { };

  # This node takes part in replication: the HCS as supplier, an idm-running
  # local gateway as consumer.
  replEnabled = replicationActive && (isHcs || (isZoneReplica && replConsumerZones ? ${zone.name}));

  # This gateway is a replication consumer (in both bootstrap steps). A consumer
  # is NEVER provisioned: it mirrors the HCS through replication, so provisioning
  # it would create a divergent DB that the supplier overwrites. (It also avoids
  # the provisioning post-start, whose readiness probe hits the web UI that a
  # WriteReplicaNoUI does not serve.)
  isReplConsumer = replEnabled && isZoneReplica;

  # A consumer only switches to the read-only role once its HCS supplier cert is
  # synced (step 2). Until then it is a WriteReplicaNoUI that boots and emits its
  # own replication identity (step 1), but stays unprovisioned (empty DB) — it
  # only serves logins once replication is established in step 2.
  isRoReplica = isReplConsumer && hcsReplCert != "";

  # Supplier side (HCS): one `allow-pull` block per zone-gateway consumer whose
  # certificate has already been synced.
  replSupplierBlocks = listToAttrs (
    filter (e: e != null) (
      mapAttrsToList (
        _: z:
        let
          cert = readReplCert z.gateway.hostname;
        in
        if cert == "" then
          null
        else
          {
            name = mkReplOrigin z.gateway.vpn.ipv4;
            value = {
              type = "allow-pull";
              consumer_cert = cert;
            };
          }
      ) replConsumerZones
    )
  );

  # Consumer side (zone gateway): a single `pull` block toward the HCS supplier.
  replConsumerBlocks = optionalAttrs (hcsReplCert != "") {
    ${hcsOrigin} = {
      type = "pull";
      supplier_cert = hcsReplCert;
      automatic_refresh = true;
    };
  };

  # Effective `replication` settings for this node (only used when replEnabled).
  replSettings = {
    origin = if isHcs then hcsOrigin else mkReplOrigin zone.gateway.vpn.ipv4;
    bindaddress = "${if isHcs then hcsVpnIp else zone.gateway.vpn.ipv4}:${toString replPort}";
  }
  // (if isHcs then replSupplierBlocks else replConsumerBlocks);

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

      # Invariant: all instances of the same clientId point to the
      # same secret name (derived from clientId by construction). The block
      # below documents this invariant and would raise a clear error if
      # `mkOauth2Clients` were to change strategy.
      assertions = map (c: {
        assertion = lib.unique (map (i: i.secret) c.instances) == [ c.secret ];
        message = "OAuth2 client '${c.clientId}': secret divergence across instances";
      }) oauth2Clients;

      #========================================================================
      # Replication firewall (HCS supplier only)
      #========================================================================

      # Consumers (zone gateways) initiate the pull connection towards the HCS,
      # so only the supplier needs the replication port reachable, and only over
      # the tailnet. Merges with the port 53 rule set by headscale.nix.
      networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = mkIf (
        replEnabled && isHcs
      ) [ replPort ];

      #========================================================================
      # Kanidm service
      #========================================================================

      systemd.services.kanidmd.serviceConfig = mkIf (!isHcs) {

        # Allow read access to vital system paths
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
        package = pkgs.kanidm_1_10.withSecretProvisioning;

        #----------------------------------------------------------------------
        # SERVER
        #----------------------------------------------------------------------

        # Manages the DB (Argon2id) and exposes API, Web + LDAP bridge interfaces (read-only).
        # -> https://github.com/kanidm/kanidm/blob/master/examples/server.toml
        server = {
          enable = true;
          settings = {
            bindaddress = "${params.ip}:${toString srvPort}";

            # Default is info
            #log_level = "debug";

            # The domain that Kanidm manages. Must be below or equal to the domain specified in serverSettings.origin.
            # Always set (same value network-wide). The kanidm 1.10 nixpkgs module
            # asserts `domain == null -> role is a Write replica`, i.e. a
            # ReadOnlyReplica MUST keep a non-null domain (it simply matches the
            # supplier's, which is identical here since the whole net shares one).
            domain = network.domain;

            # The origin of the Kanidm instance.
            origin = params.href;

            # Address and port the LDAP server is bound to. Setting this to null disables the LDAP interface.
            ldapbindaddress = mkIf isMainReplica "${host.vpnIp}:636";

            # The role of this server. This affects the replication relationship and thereby available features.
            # Scenarios 1 & 2 keep the historical behaviour. In scenario 3 the HCS
            # supplies; an idm gateway is a functional WriteReplicaNoUI in step 1
            # (emitting its identity) and flips to ReadOnlyReplica in step 2 once
            # its HCS supplier cert is synced.
            role =
              if !replEnabled then
                (if isMainReplica then "WriteReplica" else "WriteReplicaNoUI")
              else if isHcs then
                "WriteReplica"
              else if isRoReplica then
                "ReadOnlyReplica"
              else
                "WriteReplicaNoUI";

            # Internal TLS Certificates
            # openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=127.0.0.1";
            tls_chain = secrets.kanidm-tls-chain.path;
            tls_key = secrets.kanidm-tls-key.path;

            # Multi-zone replication. Emitted automatically: always on the HCS
            # supplier, and on a zone gateway once the HCS cert is synced (see
            # replEnabled). The top-level origin/bindaddress make the node
            # generate its replication identity at first boot; partner sub-blocks
            # appear once the peer certificates have been synced (see readReplCert).
            replication = mkIf replEnabled replSettings;
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

        # Unix daemon configuration for PAM/NSS (replaces SSSD)
        unix = {
          enable = !isHcs;
          settings = {
            default_shell = "/etc/profiles/per-user/nix/bin/zsh";

            # Renamed in the unixd v2 config: the PAM login groups now live under
            # the `[kanidm]` provider table (nixpkgs asserts this).
            kanidm.pam_allowed_login_groups = [ "posix" ];
          };
        };

        #----------------------------------------------------------------------
        # Provision
        #----------------------------------------------------------------------

        provision = {

          # Provisioning writes to the database, so it must never run on a
          # replication consumer (WriteReplicaNoUI in step 1, ReadOnlyReplica in
          # step 2): the consumer receives its whole state from the HCS supplier.
          # Standalone instances (scenarios 1 & 2) are provisioned as before.
          enable = !isReplConsumer;

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
