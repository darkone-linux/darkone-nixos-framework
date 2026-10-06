# DNF matrix (synapse) homeserver.
#
# Sub-modules (`matrix/`):
# - `mas.nix`: authentication, delegated to Matrix Authentication Service;
# - `bridges.nix`: mautrix bridges, usable by every local account;
# - `rtc.nix`: MatrixRTC backend (LiveKit) for Element Call.
#
# #### Federation
#
# Federation is configurable via `darkone.service.matrix.federation`:
#
# - `enable = false`: blocks all federation (empty domain whitelist).
# - `enable = true; whitelist = [ ]`: open federation with every server.
# - `enable = true; whitelist = [ "ami.org" ]`: allowlist (inbound + outbound).
#
# Discovery stays locked regardless (rooms absent from remote directories,
# profiles private over federation), so the network is reachable but not
# searchable.
#
# :::caution[Safe-for-kids]
# Open federation lets any federated server DM/invite local users. For a
# family network, fill `whitelist` with trusted servers only.
# :::
#
# Friend self-registration (`friendRegistration.enable`) opens token-gated
# local password accounts alongside Kanidm OIDC users. Mint a token on the host
# with `sudo dnf-mas manage issue-user-registration-token`.
#
# :::caution[One namespace, permanent ids]
# Friends and declared users draw from the same localpart namespace, and a
# matrix id is never freed (unique in MAS's `users`, deactivation keeps it).
# Declaring a user whose localpart a friend already took fails their first SSO
# login: MAS `on_conflict` stays on `fail`, since anything else hands the
# existing account to whoever registers a matching name upstream. Merge
# procedure in the admin guide (`operate/matrix.mdx`).
# :::
#
# #### Administrators
#
# `network.matrix.admins` (local parts) is the single declarative source for
# both administrations, applied at rebuild with no database write:
#
# - bridges: `admin` level in every mautrix `permissions` map;
# - server: `policy.data.admin_users`, which the bundled MAS policy turns into
#   the `urn:mas:admin` and `urn:synapse:admin:*` scopes (MAS admin API, synapse
#   admin API, `matrix-admin` UI login).
#
# :::caution[Imperative promotions survive]
# The policy grants admin on `admin_users` OR the `can_request_admin` database
# flag `dnf-mas manage promote-admin` sets. Audit leftovers with
# `list-admin-users`, drop them with `demote-admin`.
# :::

# TODO: Synapse Admin -> https://wiki.nixos.org/wiki/Matrix#Synapse_Admin_with_Caddy

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  network,
  host,
  zone,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.matrix;
  srv = config.services.matrix-synapse;

  # federation_domain_whitelist: absent = open; [] = block all; list =
  # allowlist. Synapse treats an empty list as a full federation block.
  federationSettings =
    lib.optionalAttrs (!cfg.federation.enable) { federation_domain_whitelist = [ ]; }
    // lib.optionalAttrs (cfg.federation.enable && cfg.federation.whitelist != [ ]) {
      federation_domain_whitelist = cfg.federation.whitelist;
    };

  synapsePort = dnfConfig.network.ports.matrix;
  masPort = dnfConfig.network.ports.matrixAuth;
  livekitPort = dnfConfig.network.ports.livekit;
  livekitJwtPort = dnfConfig.network.ports.livekitJwt;

  # MatrixRTC authorization service, stripped of its prefix (`handle_path`):
  # Element Call appends `/get_token` to the announced url.
  livekitJwtUrl = "${params.href}/livekit/jwt";

  # Stable ULID naming the Kanidm provider inside MAS. Kanidm redirect URIs
  # and every upstream account link embed it: changing it orphans all linked
  # accounts (cf. `matrix/mas.nix`).
  masKanidmUlid = "01JDNF0000000000000KAN1DM0";

  # Native Prometheus metrics, exposed only where a zone Prometheus scrapes
  # this host. Bound to the scrapeable IP (like the node exporter), not the
  # loopback the HTTP listener may use on the HCS.
  isNode = host.features ? "monitoring-node";
  metricsPort = dnfConfig.network.ports.matrixMetrics;
  metricsIp = dnfLib.preferredIp host;

  # VoIP
  inherit (config.services) coturn;
  hasTurn = coturn.enable;

  # writeShellScript, not writeScript + `#!/bin/sh`: the script uses the
  # bash-only `set -o pipefail`, which only worked because NixOS points
  # /bin/sh at bash. This pins the interpreter in the store instead.
  matrixDbInitScript = pkgs.writeShellScript "matrix-db-init.sh" ''
    set -euo pipefail

    if ! ${pkgs.postgresql}/bin/psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='matrix-synapse'" | ${pkgs.gnugrep}/bin/grep -q 1; then
      ${pkgs.postgresql}/bin/psql -c 'CREATE ROLE "matrix-synapse" LOGIN;'
    fi

    if ! ${pkgs.postgresql}/bin/psql -tAc "SELECT 1 FROM pg_database WHERE datname='matrix-synapse'" | ${pkgs.gnugrep}/bin/grep -q 1; then
      ${pkgs.postgresql}/bin/createdb --owner=matrix-synapse \
        --template=template0 \
        --encoding=UTF8 \
        --locale=C \
        matrix-synapse
    fi
  '';

  # Declared matrix administrators (local parts), single source for bridge
  # administration and for the MAS admin scopes (cf. header).
  matrixAdmins = network.matrix.admins or [ ];

  defaultParams = {
    icon = "element";
  };
  params = dnfLib.extractServiceParams host network "matrix" defaultParams;
in
{
  options = {
    darkone.service.matrix = {
      enable = lib.mkEnableOption "Enable matrix (synapse) service";

      # Server-to-server federation. Active by default but without allowlist
      # (open). Filling `whitelist` restricts inbound AND outbound to the listed
      # domains only (safest for a family network); `enable = false` blocks all.
      federation = {
        enable = lib.mkEnableOption "Allow server-to-server federation. False blocks all federation.";
        whitelist = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Empty = federate with all servers; non-empty = only these domains (inbound + outbound).";
        };
      };

      # MatrixRTC backend (`matrix/rtc.nix`). Default off: it binds a public UDP
      # range and a TCP fallback, which only a host reachable from the outside
      # can honour.
      matrixRtc.enable = lib.mkEnableOption "Enable the MatrixRTC backend (LiveKit SFU) for Element Call group calls.";

      # Local password accounts for friends, in addition to the Kanidm (OIDC)
      # users. Token-gated: no open registration without an invite token.
      friendRegistration.enable = lib.mkEnableOption "Allow friends to self-register with an invite token (token-gated).";

      # Mautrix bridges, individually switchable
      bridges = {
        whatsapp.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Mautrix WhatsApp bridge (login by QR code).";
        };
        signal.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Mautrix Signal bridge (login by QR code).";
        };
        telegram.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Mautrix Telegram bridge (login by phone number).";
        };
        messenger.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Mautrix Facebook Messenger bridge (login by cookies).";
        };
        discord.enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Mautrix Discord bridge (login by QR code, experimental).";
        };
      };

      # Values shared with the `matrix/` sub-modules.
      shared = lib.mkOption {
        type = lib.types.raw;
        internal = true;
        readOnly = true;
        default = {
          inherit
            params
            masKanidmUlid
            livekitJwtUrl
            matrixAdmins
            ;
        };
        defaultText = "computed";
        description = "Matrix values shared with the `matrix/` sub-modules.";
      };
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {

      # Kanidm OAuth2 client template
      darkone.service.idm.oauth2.matrix = {
        displayName = "Matrix Synapse";
        imageFile = ./../../assets/app-icons/synapse.svg;

        # MAS is the OIDC client, never synapse (cf. `matrix/mas.nix`).
        redirectPaths = [ "/upstream/callback/${masKanidmUlid}" ];
        landingPath = "/";
        preferShortUsername = true;
      };

      darkone.system.services.service.matrix = {
        inherit defaultParams;
        displayOnHomepage = false;
        persist.dirs = [ srv.dataDir ];

        # The vhost root belongs to MAS (login pages, `/account`, `/oauth2/*`,
        # `/upstream/callback/*`); synapse keeps its prefixes.
        proxy.servicePort = masPort;
        proxy.extraConfig = ''

          # Redirect to Synapse. The whole `/_synapse/*` prefix, admin API
          # included: MAS owns nothing under it, and with delegated auth the
          # catch-all below answers 404 with no CORS ("Failed to fetch").
          reverse_proxy /_matrix/* http://127.0.0.1:${toString synapsePort}
          reverse_proxy /_synapse/* http://127.0.0.1:${toString synapsePort}
        ''
        + ''

          # MAS owns the whole compat auth surface, sub-paths
          # included (`logout/all`, and the legacy `login/sso/redirect[/<idp>]`
          # that Element Desktop and every pre-OIDC client still use). Synapse
          # answers M_UNRECOGNIZED on all of them once auth is delegated.
          #
          # A regex matcher, not path matchers: Caddy compares a trailing `*`
          # as a literal prefix, so `/_matrix/client/*/login/*` would never
          # match. `handle` also outranks the `reverse_proxy` block below.
          @masCompat path_regexp ^/_matrix/client/[^/]+/(login|logout|refresh)(/.*)?$
          handle @masCompat {
            reverse_proxy http://127.0.0.1:${toString masPort}
          }
        ''
        + lib.optionalString cfg.matrixRtc.enable ''

          # MatrixRTC backend, sharing this vhost so no extra subdomain or
          # certificate is needed. Both prefixes are stripped: Element Call
          # appends `/get_token` to the announced JWT url, and livekit-client
          # appends `/rtc` to the SFU url the JWT service hands back, while
          # both daemons serve those paths at their own root.
          handle_path /livekit/jwt/* {
            reverse_proxy http://127.0.0.1:${toString livekitJwtPort}
          }
          handle_path /livekit/sfu/* {
            reverse_proxy http://127.0.0.1:${toString livekitPort}
          }
        ''
        + ''

          # Helps mobile clients to find the server (and, with MatrixRTC, the
          # clients too old to read `matrix_rtc.transports` off synapse)
          ${dnfLib.mkMatrixWellKnown {
            inherit (network) domain;
            rtcFociUrl = if cfg.matrixRtc.enable then livekitJwtUrl else null;
          }}
        '';
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "matrix";

      # Expose the Synapse metrics listener to the zone Prometheus over the
      # internal interface (no-op on a gateway, scraped locally there).
      networking.firewall = lib.mkIf isNode (dnfLib.mkInternalFirewall host zone [ metricsPort ]);

      #------------------------------------------------------------------------
      # Sops
      #------------------------------------------------------------------------

      # Coturn secret
      sops.secrets.turn-secret-matrix = lib.mkIf hasTurn {
        mode = "0400";
        owner = "matrix-synapse";
        key = "turn-secret";
      };

      #------------------------------------------------------------------------
      # Database
      #------------------------------------------------------------------------

      systemd.services.matrix-db-init = {
        description = "Create Synapse database with C collation if missing";
        after = [ "postgresql.service" ];
        requires = [ "postgresql.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "postgres";
          ExecStart = "${matrixDbInitScript}";
        };
      };
      services.postgresql = {
        enable = true;
        ensureUsers = [ { name = "matrix-synapse"; } ];
      };

      # PostgreSQL backup (all databases by default)
      services.postgresqlBackup.enable = true;

      #------------------------------------------------------------------------
      # Synapse Server
      #------------------------------------------------------------------------

      # TODO: manhole for admin debugging? https://element-hq.github.io/synapse/latest/manhole.html

      services.matrix-synapse = {
        enable = true;
        configureRedisLocally = true;

        # https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html
        settings = {

          # General settings
          server_name = network.domain;
          public_baseurl = params.href + "/";

          # Default client location
          web_client_location = "https://element.${network.domain}/"; # TODO: autodetect

          # Delegates the following url to synapse only if bound to the network domain
          # and not a subdomain (matrix.mydomain.tld).
          # -> https://<server_name>/.well-known/matrix/server
          serve_server_wellknown = false;

          # Require authentication to find users.
          require_auth_for_profile_requests = true;

          # Keep users private from federation.
          # -> Do not allow user discovery from federation.
          allow_profile_lookup_over_federation = false;

          # Do not allow device discovery from federation.
          allow_device_name_lookup_over_federation = false;

          # No need to share a common room to find a profile.
          limit_profile_requests_to_users_who_share_rooms = false;

          # Must be authenticated to connect to public rooms. (default false)
          allow_public_rooms_without_auth = false;

          # Do not expose public rooms to federation. (default false)
          allow_public_rooms_over_federation = false;

          # Allow room publication in the public room directory
          # https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#room_list_publication_rules
          room_list_publication_rules = [ { action = "allow"; } ];

          # Federation scope: `federationSettings`, below. `ip_range_blacklist`
          # keeps its default: no outbound request to private networks.

          # Listeners. The metrics listener is appended last so the proxy's
          # `listeners[0]` reference keeps pointing at the HTTP listener.
          listeners = [
            {
              port = synapsePort;
              bind_addresses = [ params.ip ];
              type = "http";
              tls = false;
              x_forwarded = true;
              resources = [
                {
                  names = [
                    "client" # Clients (element, ...), implies media and static
                    "federation" # Server to server, implies media, keys and openid
                  ];
                  compress = true;
                }
              ];
            }
          ]
          ++ lib.optional isNode {
            port = metricsPort;
            bind_addresses = [ metricsIp ];
            type = "metrics";
            tls = false;
            resources = [ { names = [ "metrics" ]; } ];
          };

          # TODO: https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#email

          # Homeserver specific settings
          admin_contact = "admin@${network.domain}";
          hs_disabled = false; # Server disable flag...
          hs_disabled_message = "Maintenance...";
          max_avatar_size = "1M";

          # Left at their defaults, to tune if needed: `limit_remote_rooms`
          # (performance), `retention` (messages), `media_retention`.

          # Media store
          max_upload_size = "100M";
          max_image_pixels = "50M";
          dynamic_thumbnails = false; # Resize based on clients, see if useful...

          # Rooms
          encryption_enabled_by_default_for_room_type = "all";
          user_directory = {
            enabled = false;
            search_all_users = true;
            prefer_local_users = true;
            exclude_remote_users = true;
            show_locked_users = true;
          };

          enable_metrics = isNode;

          # Registration belongs to MAS (`account.*` in `matrix/mas.nix`):
          # synapse refuses any auth config once delegated.
          enable_registration = false;
          suppress_key_server_warning = true;
          auto_join_rooms = [ ]; # TODO

          # DB
          database.args = {
            user = "matrix-synapse";
            database = "matrix-synapse";
          };

          # Coturn (visio)
          turn_uris = lib.optionals hasTurn [

            # STUN -> Many WebRTC clients (especially mobile) try STUN first before falling back to TURN.
            "stun:turn.${network.domain}:${toString coturn.listening-port}"

            # Standard TURN (UDP preferred)
            "turn:turn.${network.domain}:${toString coturn.listening-port}?transport=udp"
            "turn:turn.${network.domain}:${toString coturn.listening-port}?transport=tcp"

            # Secure TURN: TLS runs over TCP only
            "turns:turn.${network.domain}:${toString coturn.tls-listening-port}?transport=tcp"
          ];
          turn_shared_secret_path = lib.mkIf hasTurn config.sops.secrets.turn-secret-matrix.path;
          turn_user_lifetime = lib.mkIf hasTurn "24h";
          turn_allow_guests = true; # Default... see if false would be better.

          # TODO: https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#registration
        };
      }; # matrix-synapse
    })

    # Federation scope. Kept in a dedicated block: `settings` is an option, so
    # we complete it here to add/omit `federation_domain_whitelist` cleanly
    # (open federation requires the key to be absent, not an empty list).
    (lib.mkIf cfg.enable { services.matrix-synapse.settings = federationSettings; })
  ];
}
