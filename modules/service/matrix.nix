# DNF matrix (synapse) server with mautrix bridges.
#
# Bridges (whatsapp, signal, telegram, messenger, discord) are usable by every
# local account: each user links its own remote account by talking to the
# bridge bot (`@whatsappbot`, `@signalbot`, ... then `login`); sessions are
# isolated per user. The declared `network.matrix.admin` administrates the
# bridges.
#
# Double puppeting uses the official appservice method
# (https://docs.mau.fi/bridges/general/double-puppeting.html): a shared
# `doublepuppet` appservice token lets bridges send remote-originated messages
# as the user's real matrix account. Required sops secrets:
# `mautrix-doublepuppet-as-token` and `mautrix-doublepuppet-hs-token`
# (`openssl rand -hex 32` each).
#
# Every bridge's appservice as/hs tokens are sops-provided rather than
# auto-generated: the registration file becomes a pure function of the
# secrets, so resetting a bridge's state dir never invalidates the
# registration synapse has loaded (which would otherwise require a registration
# wipe + synapse restart and produce "as_token was not accepted" errors).

# (TODO: Livekit -> https://wiki.nixos.org/wiki/Matrix#Livekit)
# TODO: Synapse Admin -> https://wiki.nixos.org/wiki/Matrix#Synapse_Admin_with_Caddy

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  network,
  host,
  hosts,
  zone,
  pkgs,
  ...
}:
let
  inherit network;
  cfg = config.darkone.service.matrix;
  srv = config.services.matrix-synapse;
  synapsePort = dnfConfig.network.ports.matrix;
  telegramPort = dnfConfig.network.ports.matrixTelegram;
  discordPort = dnfConfig.network.ports.matrixDiscord;

  # Native Prometheus metrics, exposed only where a zone Prometheus scrapes
  # this host. Bound to the scrapeable IP (like the node exporter), not the
  # loopback the HTTP listener may use on the HCS.
  isNode = host.features ? "monitoring-node";
  metricsPort = dnfConfig.network.ports.matrixMetrics;
  metricsIp = dnfLib.preferredIp host;

  # VoIP
  inherit (config.services) coturn;
  hasTurn = coturn.enable;

  matrixDbInitScript = pkgs.writeScript "matrix-db-init.sh" ''
    #!/bin/sh
    set -euo pipefail

    if ! ${pkgs.postgresql}/bin/psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='matrix-synapse'" | grep -q 1; then
      ${pkgs.postgresql}/bin/psql -c 'CREATE ROLE "matrix-synapse" LOGIN;'
    fi

    if ! ${pkgs.postgresql}/bin/psql -tAc "SELECT 1 FROM pg_database WHERE datname='matrix-synapse'" | grep -q 1; then
      ${pkgs.postgresql}/bin/createdb --owner=matrix-synapse \
        --template=template0 \
        --encoding=UTF8 \
        --locale=C \
        matrix-synapse
    fi
  '';

  # Mautrix settings shared by every bridge
  mautrixCommonSettings = {
    homeserver = {
      address = "http://localhost:${toString synapsePort}";
      domain = config.services.matrix-synapse.settings.server_name;
      verify_ssl = false;
    };
  };

  # Every local account may use a bridge with its own remote account; the
  # declared matrix admin gets bridge administration. The user level differs
  # per bridge generation: bridgev2/go expect "user", legacy telegram needs
  # "full" to allow own-account login.
  mkBridgePermissions =
    userLevel:
    {
      "${network.domain}" = userLevel;
    }
    // lib.optionalAttrs (network ? matrix && network.matrix ? admin) {
      "@${network.matrix.admin}:${network.domain}" = "admin";
    };

  # Official appservice double puppeting: one shared as_token for all bridges,
  # substituted by envsubst from each bridge's environmentFile.
  doublePuppetSecret = "as_token:$MAUTRIX_DOUBLEPUPPET_AS_TOKEN";

  defaultParams = {
    icon = "element";
  };
  params = dnfLib.extractServiceParams host network "matrix" defaultParams;

  inherit
    (dnfLib.mkOidcContext {
      name = "matrix";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;
in
{
  options = {
    darkone.service.matrix = {
      enable = lib.mkEnableOption "Enable matrix (synapse) service";

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

        # -> https://element-hq.github.io/synapse/latest/openid.html
        redirectPaths = [ "/_synapse/client/oidc/callback" ];
        landingPath = "/";
        preferShortUsername = true;
      };

      darkone.system.services.service.matrix = {
        inherit defaultParams;
        displayOnHomepage = false;
        persist.dirs = [ srv.dataDir ];
        proxy.servicePort = (builtins.elemAt srv.settings.listeners 0).port;
        proxy.extraConfig = ''

          # Redirect to Synapse
          reverse_proxy /_matrix/* http://127.0.0.1:${toString synapsePort}
          reverse_proxy /_synapse/client/* http://127.0.0.1:${toString synapsePort}

          # Helps mobile clients to find the server
          handle /.well-known/matrix/client {
            header Access-Control-Allow-Origin "*"
            header Content-Type "application/json"
            respond `{"m.homeserver":{"base_url":"https://matrix.${network.domain}"}}`
          }

          # Federation
          handle /.well-known/matrix/server {
            header Access-Control-Allow-Origin "*"
            header Content-Type "application/json"
            respond `{"m.server":"matrix.${network.domain}:443"}`
          }
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

      # Registration Shared Secret
      sops.secrets.matrix-rss-password = {
        mode = "0400";
        owner = "matrix-synapse";
      };

      # OIDC secret
      # -> Note: put client secret in extra config do not works.
      sops.secrets.${secret} = { };
      sops.templates.oidc-secret-synapse = {
        content = config.sops.placeholder.${secret};
        mode = "0400";
        owner = "matrix-synapse";
      };

      # Coturn secret
      sops.secrets.turn-secret-matrix = lib.mkIf hasTurn {
        mode = "0400";
        owner = "matrix-synapse";
        key = "turn-secret";
      };

      # Double puppeting appservice: a single shared as_token allows every
      # bridge to impersonate local users (official docs.mau.fi method). The
      # hs_token is required by synapse but never used.
      sops.secrets.mautrix-doublepuppet-as-token = { };
      sops.secrets.mautrix-doublepuppet-hs-token = { };
      sops.templates.doublepuppet-registration = {
        content = ''
          id: doublepuppet
          url:
          as_token: ${config.sops.placeholder.mautrix-doublepuppet-as-token}
          hs_token: ${config.sops.placeholder.mautrix-doublepuppet-hs-token}
          sender_localpart: doublepuppet
          rate_limited: false
          namespaces:
            users:
              - regex: '@.*:${network.domain}'
                exclusive: false
        '';
        mode = "0400";
        owner = "matrix-synapse";
        restartUnits = [ "matrix-synapse.service" ];
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

      # Used by mautrix bridges for conversions; olm is required by legacy
      # bridges and is flagged insecure upstream.
      environment.systemPackages = [ pkgs.ffmpeg_7 ];
      nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

      #------------------------------------------------------------------------
      # Synapse Server
      #------------------------------------------------------------------------

      # TODO: voir si c'est utile pour admin : https://element-hq.github.io/synapse/latest/manhole.html

      services.matrix-synapse = {
        enable = true;
        configureRedisLocally = true;
        #extraConfigFiles = lib.optional hasTurn config.sops.templates."synapse-extra-config.yml".path;

        # https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html
        settings = {

          # General settings
          #server_name = params.fqdn;
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

          # Federation restrictions
          #federation_domain_whitelist = []; # Whitelist of allowed servers (default: all)
          #federation_whitelist_endpoint_enabled = true; # Expose this list (default: false)

          # Keep default values: do not allow synapse to make outbound requests
          # to private networks -> https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#ip_range_blacklist
          #ip_range_blacklist
          #ip_range_whitelist

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
                    "client" # Client (element, ...), implique [ media, static ]
                    "federation" # Connexions serveur-serveur, implique [ media, keys, openid ]
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
          #email = { };

          # Homeserver specific settings
          admin_contact = "admin@${network.domain}";
          hs_disabled = false; # Server disable flag...
          hs_disabled_message = "Maintenance...";
          #limit_remote_rooms # TODO if perf. problems
          max_avatar_size = "1M";
          #retention # Message retention policy if needed (default false)

          # Media store
          max_upload_size = "100M";
          max_image_pixels = "50M";
          dynamic_thumbnails = false; # Resize based on clients, see if useful...
          #media_retention # https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#media_retention

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
          enable_registration = false;
          suppress_key_server_warning = true;
          registration_shared_secret_path = config.sops.secrets.matrix-rss-password.path;
          auto_join_rooms = [ ]; # TODO

          # Double puppeting appservice for the mautrix bridges (the bridges'
          # own registrations are appended by their nixpkgs modules)
          app_service_config_files = [ config.sops.templates.doublepuppet-registration.path ];

          # DB
          database.args = {
            user = "matrix-synapse";
            database = "matrix-synapse";
          };

          # Kanidm
          oidc_providers = [
            {
              idp_id = "kanidm";
              idp_name = "IDM";
              issuer = oidc.issuerUrl;
              client_id = clientId;
              client_secret_path = config.sops.templates.oidc-secret-synapse.path;
              scopes = [
                "openid"
                "profile"
              ];
              user_mapping_provider.config = {
                localpart_template = "{{ user.preferred_username.split('@')[0] | lower }}";
                display_name_template = "{{ user.displayname }}";
              };
            }
          ];

          # Coturn (visio)
          turn_uris = lib.optionals hasTurn [

            # STUN -> Many WebRTC clients (especially mobile) try STUN first before falling back to TURN.
            "stun:turn.${network.domain}:${toString coturn.listening-port}"

            # Standard TURN (UDP preferred)
            "turn:turn.${network.domain}:${toString coturn.listening-port}?transport=udp"
            "turn:turn.${network.domain}:${toString coturn.listening-port}?transport=tcp"

            # Secure TURN (TLS, TCP)
            "turns:turn.${network.domain}:${toString coturn.tls-listening-port}?transport=tcp"

            # UDP does not really exist, keep only TCP for TLS
            # "turns:turn.${network.domain}:${toString coturn.tls-listening-port}?transport=udp"
          ];
          turn_shared_secret_path = lib.mkIf hasTurn config.sops.secrets.turn-secret-matrix.path;
          turn_user_lifetime = lib.mkIf hasTurn "24h";
          turn_allow_guests = true; # Default... see if false would be better.

          # TODO: https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#registration
        };
      }; # matrix-synapse
    })

    #------------------------------------------------------------------------
    # Mautrix bridge: Facebook Messenger (bridgev2)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.messenger.enable) {

      sops.secrets.mautrix-meta-as-token = { };
      sops.secrets.mautrix-meta-hs-token = { };
      sops.secrets.mautrix-meta-encryption-pickle-key = { };
      sops.templates.mautrix-meta-env = {
        content = ''
          MAUTRIX_META_APPSERVICE_AS_TOKEN=${config.sops.placeholder.mautrix-meta-as-token}
          MAUTRIX_META_APPSERVICE_HS_TOKEN=${config.sops.placeholder.mautrix-meta-hs-token}
          ENCRYPTION_PICKLE_KEY=${config.sops.placeholder.mautrix-meta-encryption-pickle-key}
          MAUTRIX_DOUBLEPUPPET_AS_TOKEN=${config.sops.placeholder.mautrix-doublepuppet-as-token}
        '';
        mode = "0400";
        owner = "mautrix-meta-messenger";

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "mautrix-meta-messenger.service" ];
      };

      services.mautrix-meta.instances.messenger = {
        enable = true;
        environmentFile = config.sops.templates.mautrix-meta-env.path;
        settings = mautrixCommonSettings // {
          network.mode = "messenger";
          network.chat_sync_max_age = "168h"; # only sync active conversations from the last 7 days
          bridge.permissions = mkBridgePermissions "user";
          double_puppet.secrets."${network.domain}" = doublePuppetSecret;

          # The nixpkgs mautrix-meta defaults are stricter than the other
          # bridges: `require = true` makes the bot ignore unencrypted rooms
          # and `cross-signed-tofu` silently drops messages from unverified
          # sessions — the bot never answers. Align on whatsapp/signal
          # (mautrix upstream defaults). Changing pickle_key from the module
          # default requires a bridge state reset (/var/lib/mautrix-meta-*).
          encryption = {
            allow = true;
            default = true;
            require = false;
            pickle_key = "$ENCRYPTION_PICKLE_KEY";
            verification_levels = {
              receive = "unverified";
              send = "unverified";
              share = "cross-signed-tofu";
            };

            # Aggressive key deletion is only sensible with enforced
            # verification; back to mautrix defaults like the other bridges.
            delete_keys = {
              dont_store_outbound = false;
              ratchet_on_decrypt = false;
              delete_fully_used_on_decrypt = false;
              delete_prev_on_new_session = false;
              delete_on_device_delete = false;
              periodically_delete_expired = false;
              delete_outdated_inbound = false;
            };
          };
          appservice = {
            id = "messenger";

            # Deterministic registration tokens (cf. file header)
            as_token = "$MAUTRIX_META_APPSERVICE_AS_TOKEN";
            hs_token = "$MAUTRIX_META_APPSERVICE_HS_TOKEN";
            bot = {
              username = "messengerbot";
              displayname = "Messenger bridge bot";
              avatar = "mxc://maunium.net/ygtkteZsXnGJLJHRchUwYWak";
            };
          };
        };
      };
    })

    #------------------------------------------------------------------------
    # Mautrix bridge: WhatsApp (bridgev2)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.whatsapp.enable) {

      sops.secrets.mautrix-whatsapp-as-token = { };
      sops.secrets.mautrix-whatsapp-hs-token = { };
      sops.secrets.mautrix-whatsapp-encryption-pickle-key = { };
      sops.templates.mautrix-whatsapp-env = {
        content = ''
          MAUTRIX_WHATSAPP_APPSERVICE_AS_TOKEN=${config.sops.placeholder.mautrix-whatsapp-as-token}
          MAUTRIX_WHATSAPP_APPSERVICE_HS_TOKEN=${config.sops.placeholder.mautrix-whatsapp-hs-token}
          ENCRYPTION_PICKLE_KEY=${config.sops.placeholder.mautrix-whatsapp-encryption-pickle-key}
          MAUTRIX_DOUBLEPUPPET_AS_TOKEN=${config.sops.placeholder.mautrix-doublepuppet-as-token}
        '';
        mode = "0400";
        owner = "mautrix-whatsapp";

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "mautrix-whatsapp.service" ];
      };

      services.mautrix-whatsapp = {
        enable = true;
        environmentFile = config.sops.templates.mautrix-whatsapp-env.path;
        settings = lib.mkMerge [
          mautrixCommonSettings
          {
            bridge.permissions = mkBridgePermissions "user";
            double_puppet.secrets."${network.domain}" = doublePuppetSecret;

            # Deterministic registration tokens (cf. file header)
            appservice = {
              as_token = "$MAUTRIX_WHATSAPP_APPSERVICE_AS_TOKEN";
              hs_token = "$MAUTRIX_WHATSAPP_APPSERVICE_HS_TOKEN";
            };

            # Do not bridge WhatsApp statuses: the default (true) keeps
            # re-inviting every user to a "WhatsApp Status Broadcast" room.
            network.enable_status_broadcast = false;

            encryption = {
              allow = true;
              default = true;
              pickle_key = "$ENCRYPTION_PICKLE_KEY";
              require = false;
            };
          }
        ];
      };
    })

    #------------------------------------------------------------------------
    # Mautrix bridge: Signal (bridgev2)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.signal.enable) {

      sops.secrets.mautrix-signal-as-token = { };
      sops.secrets.mautrix-signal-hs-token = { };
      sops.secrets.mautrix-signal-encryption-pickle-key = { };
      sops.templates.mautrix-signal-env = {
        content = ''
          MAUTRIX_SIGNAL_APPSERVICE_AS_TOKEN=${config.sops.placeholder.mautrix-signal-as-token}
          MAUTRIX_SIGNAL_APPSERVICE_HS_TOKEN=${config.sops.placeholder.mautrix-signal-hs-token}
          ENCRYPTION_PICKLE_KEY=${config.sops.placeholder.mautrix-signal-encryption-pickle-key}
          MAUTRIX_DOUBLEPUPPET_AS_TOKEN=${config.sops.placeholder.mautrix-doublepuppet-as-token}
        '';
        mode = "0400";
        owner = "mautrix-signal";

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "mautrix-signal.service" ];
      };

      services.mautrix-signal = {
        enable = true;
        environmentFile = config.sops.templates.mautrix-signal-env.path;
        settings = lib.mkMerge [
          mautrixCommonSettings
          {
            bridge.permissions = mkBridgePermissions "user";
            double_puppet.secrets."${network.domain}" = doublePuppetSecret;

            # Deterministic registration tokens (cf. file header)
            appservice = {
              as_token = "$MAUTRIX_SIGNAL_APPSERVICE_AS_TOKEN";
              hs_token = "$MAUTRIX_SIGNAL_APPSERVICE_HS_TOKEN";
            };

            encryption = {
              allow = true;
              default = true;
              pickle_key = "$ENCRYPTION_PICKLE_KEY";
              require = false;
            };
          }
        ];
      };
    })

    #------------------------------------------------------------------------
    # Mautrix bridge: Telegram (legacy python bridge)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.telegram.enable) {

      # API credentials -> https://my.telegram.org/
      sops.secrets.mautrix-telegram-api-id = { };
      sops.secrets.mautrix-telegram-api-hash = { };
      sops.secrets.mautrix-telegram-as-token = { };
      sops.secrets.mautrix-telegram-hs-token = { };
      sops.templates.mautrix-telegram-env = {
        content = ''
          MAUTRIX_TELEGRAM_API_ID=${config.sops.placeholder.mautrix-telegram-api-id}
          MAUTRIX_TELEGRAM_API_HASH=${config.sops.placeholder.mautrix-telegram-api-hash}
          MAUTRIX_TELEGRAM_APPSERVICE_AS_TOKEN=${config.sops.placeholder.mautrix-telegram-as-token}
          MAUTRIX_TELEGRAM_APPSERVICE_HS_TOKEN=${config.sops.placeholder.mautrix-telegram-hs-token}
          MAUTRIX_DOUBLEPUPPET_AS_TOKEN=${config.sops.placeholder.mautrix-doublepuppet-as-token}
        '';
        mode = "0400";
        owner = "mautrix-telegram";

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "mautrix-telegram.service" ];
      };

      services.mautrix-telegram = {
        enable = true;
        environmentFile = config.sops.templates.mautrix-telegram-env.path;
        settings = lib.mkMerge [
          mautrixCommonSettings
          {
            telegram = {
              api_id = "$MAUTRIX_TELEGRAM_API_ID";
              api_hash = "$MAUTRIX_TELEGRAM_API_HASH";
              bot_token = "disabled";
            };
            appservice = {
              id = "telegram";
              address = "http://localhost:${toString telegramPort}"; # 8080 by default already in use
              port = telegramPort;
              as_token = "$MAUTRIX_TELEGRAM_APPSERVICE_AS_TOKEN";
              hs_token = "$MAUTRIX_TELEGRAM_APPSERVICE_HS_TOKEN";
            };
            bridge = {

              # Legacy levels: "full" (not "user") is required so that local
              # accounts can log into their own telegram account.
              permissions = mkBridgePermissions "full";
              login_shared_secret_map."${network.domain}" = doublePuppetSecret;
              encryption = {
                allow = true;
                default = true;
                msc4190 = true;
                require = false;
              };
            };
          }
        ];
      };
    })

    #------------------------------------------------------------------------
    # Mautrix bridge: Discord (legacy go bridge, optional)
    #------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && cfg.bridges.discord.enable) {

      sops.secrets.mautrix-discord-as-token = { };
      sops.secrets.mautrix-discord-hs-token = { };
      sops.templates.mautrix-discord-env = {
        content = ''
          MAUTRIX_DISCORD_APPSERVICE_AS_TOKEN=${config.sops.placeholder.mautrix-discord-as-token}
          MAUTRIX_DISCORD_APPSERVICE_HS_TOKEN=${config.sops.placeholder.mautrix-discord-hs-token}
          MAUTRIX_DOUBLEPUPPET_AS_TOKEN=${config.sops.placeholder.mautrix-doublepuppet-as-token}
        '';
        mode = "0400";
        owner = "mautrix-discord";

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "mautrix-discord.service" ];
      };

      services.mautrix-discord = {
        enable = true;
        environmentFile = config.sops.templates.mautrix-discord-env.path;
        settings = {
          homeserver = mautrixCommonSettings.homeserver;

          # Deterministic registration tokens (cf. file header). The module's
          # appservice option is a non-merging attrs: setting the tokens
          # replaces its default wholesale, so the upstream values must be
          # restated here.
          appservice = {
            address = "http://localhost:${toString discordPort}";
            hostname = "0.0.0.0";
            port = discordPort;
            database = {
              type = "sqlite3";
              uri = "file:/var/lib/mautrix-discord/mautrix-discord.db?_txlock=immediate";
              max_open_conns = 20;
              max_idle_conns = 2;
              max_conn_idle_time = null;
              max_conn_lifetime = null;
            };
            id = "discord";
            bot = {
              username = "discordbot";
              displayname = "Discord bridge bot";
              avatar = "mxc://maunium.net/nIdEykemnwdisvHbpxflpDlC";
            };
            ephemeral_events = true;
            async_transactions = false;
            as_token = "$MAUTRIX_DISCORD_APPSERVICE_AS_TOKEN";
            hs_token = "$MAUTRIX_DISCORD_APPSERVICE_HS_TOKEN";
          };

          # Intentionally partial: missing keys (templates, command prefix...)
          # are filled at startup by the bridge's embedded config upgrader.
          bridge = {
            permissions = mkBridgePermissions "user" // {
              "*" = "relay";
            };
            login_shared_secret_map."${network.domain}" = doublePuppetSecret;
          };
        };
      };
    })
  ];
}
