# DNF matrix (synapse) server.

# (TODO: Livekit -> https://wiki.nixos.org/wiki/Matrix#Livekit)
# TODO: Synapse Admin -> https://wiki.nixos.org/wiki/Matrix#Synapse_Admin_with_Caddy

{
  lib,
  dnfLib,
  config,
  network,
  host,
  hosts,
  pkgs,
  ...
}:
let
  inherit network;
  cfg = config.darkone.service.matrix;
  srv = config.services.matrix-synapse;
  synapsePort = 8008;

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

  # Mautrix - TODO: auto permissions
  mautrixCommonSettings = {
    homeserver = {
      address = "http://localhost:8008";
      #address = "https://matrix.${network.domain}";
      domain = config.services.matrix-synapse.settings.server_name;
      verify_ssl = false;
    };
    # appservice.public = {
    #   hostname = "127.0.0.1";
    # };
    bridge = {
      permissions = {
        "@guillaume:${network.domain}" = "admin";
        "${network.domain}" = "user";
      };
    };
  };

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
    darkone.service.matrix.enable = lib.mkEnableOption "Enable matrix (synapse) service";
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
          reverse_proxy /_matrix/* http://127.0.0.1:8008
          reverse_proxy /_synapse/client/* http://127.0.0.1:8008

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

      # Mautrix Whatsapp Secrets
      sops.secrets.mautrix-whatsapp-bridge-login-shared-secret = { };
      sops.secrets.mautrix-whatsapp-encryption-pickle-key = { };
      sops.templates.mautrix-whatsapp-env = {
        content = ''
          MAUTRIX_WHATSAPP_BRIDGE_LOGIN_SHARED_SECRET=${config.sops.placeholder.mautrix-whatsapp-bridge-login-shared-secret}
          ENCRYPTION_PICKLE_KEY=${config.sops.placeholder.mautrix-whatsapp-encryption-pickle-key}
        '';
        mode = "0400";
        owner = "mautrix-whatsapp";

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "mautrix-whatsapp.service" ];
      };

      # Mautrix Meta
      sops.secrets.mautrix-meta-as-token = { };
      sops.templates.mautrix-meta-env = {
        content = ''
          MAUTRIX_META_APPSERVICE_AS_TOKEN=${config.sops.placeholder.mautrix-meta-as-token}
        '';
        mode = "0400";
        owner = "mautrix-meta-messenger";

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "mautrix-meta-messenger.service" ];
      };

      # Mautrix Telegram -> https://my.telegram.org/
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
        '';
        mode = "0400";
        owner = "mautrix-telegram";

        # TODO: WARN: restarting or reloading systemd units from the activation script is deprecated and will be removed in NixOS 26.11.
        restartUnits = [ "mautrix-telegram.service" ];
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
      # Mautrix
      #------------------------------------------------------------------------

      # Facebook messenger (TODO: optimiser, conf instable)
      services.mautrix-meta.instances.messenger = {
        enable = true;
        environmentFile = config.sops.templates.mautrix-meta-env.path;
        settings = mautrixCommonSettings // {
          network.mode = "messenger";
          network.chat_sync_max_age = "168h"; # only sync active conversations from the last 7 days
          appservice = {
            id = "messenger";
            as_token = "$MAUTRIX_META_APPSERVICE_AS_TOKEN";
            bot = {
              username = "messengerbot";
              displayname = "Messenger bridge bot";
              avatar = "mxc://maunium.net/ygtkteZsXnGJLJHRchUwYWak";
            };
          };
        };
      };

      # TODO: Mautrix discord (need the discord mobile app)
      # services.mautrix-discord = {
      #   enable = true;
      #   settings = mautrixCommonSettings;
      # };

      # Whatsapp
      services.mautrix-whatsapp = {
        enable = true;
        environmentFile = config.sops.templates.mautrix-whatsapp-env.path;
        settings = lib.mkMerge [
          mautrixCommonSettings
          {
            encryption = {
              allow = true;
              default = true;
              pickle_key = "$ENCRYPTION_PICKLE_KEY";
              require = false;
            };
          }
        ];
      };
      nixpkgs.config.permittedInsecurePackages = [ "olm-3.2.16" ];

      # Telegram
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
              # device_info = {
              #   lang_code = zone.lang;
              #   system_lang_code = zone.lang;
              # };
            };
            appservice = {
              id = "telegram";
              address = "http://localhost:29317"; # 8080 by default already in use
              port = 29317;
              #bot_avatar = "remove"; # Error with the default avatar...
              as_token = "$MAUTRIX_TELEGRAM_APPSERVICE_AS_TOKEN";
              hs_token = "$MAUTRIX_TELEGRAM_APPSERVICE_HS_TOKEN";
            };
            bridge = {
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

      # Used by mautrix bridges for conversions
      environment.systemPackages = with pkgs; [ ffmpeg_7 ];

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

          # Listeners
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
          ];

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

          enable_metrics = false;
          enable_registration = false;
          suppress_key_server_warning = true;
          registration_shared_secret_path = config.sops.secrets.matrix-rss-password.path;
          auto_join_rooms = [ ]; # TODO

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
  ];
}
