# DNF matrix (synapse) server.

# (TODO: Livekit -> https://wiki.nixos.org/wiki/Matrix#Livekit)
# TODO: intégration jitsi
# TODO: Synapse Admin -> https://wiki.nixos.org/wiki/Matrix#Synapse_Admin_with_Caddy

{
  lib,
  dnfLib,
  config,
  network,
  host,
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
  # mautrixCommonSettings = {
  #   homeserver = {
  #     address = "http://localhost:8008";
  #     domain = "matrix.${network.domain}";
  #   };
  #   # appservice.public = {
  #   #   hostname = "127.0.0.1";
  #   # };
  #   bridge = {
  #     permissions = {
  #       "@guillaume:${network.domain}" = "admin";
  #       "${network.domain}" = "user";
  #     };
  #   };
  # };

  defaultParams = {
    icon = "element";
  };
  params = dnfLib.extractServiceParams host network "matrix" defaultParams;
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
      darkone.system.services = {
        enable = true;
        service.matrix.enable = true;
      };

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
      sops.secrets.oidc-secret-matrix-synapse = { };
      sops.templates.oidc-secret-synapse = {
        content = config.sops.placeholder.oidc-secret-matrix-synapse;
        mode = "0400";
        owner = "matrix-synapse";
      };

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

      # Sauvegarde postgresql (par défaut toutes les bases)
      services.postgresqlBackup.enable = true;

      #------------------------------------------------------------------------
      # Mautrix
      #------------------------------------------------------------------------

      # services.mautrix-discord.enable = true;
      # services.mautrix-whatsapp = {
      #   enable = true;
      #   settings = mautrixCommonSettings // {
      #     appservice = {
      #       ephemeral_events = false;
      #       id = "whatsapp";
      #     };
      #     encryption = {
      #       allow = true;
      #       default = true;
      #       pickle_key = "$ENCRYPTION_PICKLE_KEY";
      #       require = true;
      #     };
      #   };
      # };

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

          # Généralités
          #server_name = params.fqdn;
          server_name = network.domain;
          public_baseurl = params.href + "/";

          # Default client location
          web_client_location = "https://element.${network.domain}/"; # TODO: autodetect

          # Délègue l'url suivante à synapse si celui-ci est bindé sur le domaine du network uniquement
          # et non un sous domaine (matrix.mondomaine.tld).
          # -> https://<server_name>/.well-known/matrix/server
          serve_server_wellknown = false;

          # Etre authentifié pour trouver mes users.
          require_auth_for_profile_requests = true;

          # Rendre mes users confidentiels depuis la fédération.
          # -> Ne pas permettre de découvrir mes users depuis la fédération.
          allow_profile_lookup_over_federation = false;

          # Ne pas permettre la découverte des devices depuis la fédération
          allow_device_name_lookup_over_federation = false;

          # Il n'y a pas besoin de partager un salon commun pour trouver un profil.
          limit_profile_requests_to_users_who_share_rooms = false;

          # Il faut être authentifié pour se connecter aux salons publics. (default false)
          allow_public_rooms_without_auth = false;

          # Ne pas exposer mes salons publics à la fédération. (default false)
          allow_public_rooms_over_federation = false;

          # Permet la publication des rooms dans le répertoire de salons publics
          # https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#room_list_publication_rules
          room_list_publication_rules = [ { action = "allow"; } ];

          # Federation restrictions
          #federation_domain_whitelist = []; # Liste blanche des serveurs autorisés (default: tout)
          #federation_whitelist_endpoint_enabled = true; # Exposer cette liste (default: false)

          # Laisser ces valeurs par défaut: ne pas autoriser synapse a faire des requêtes sortantes
          # vers mes réseaux privés -> https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#ip_range_blacklist
          #ip_range_blacklist
          #ip_range_whitelist

          # Requêtes à écouter
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
          hs_disabled = false; # Désactivation du serveur...
          hs_disabled_message = "Maintenance...";
          #limit_remote_rooms # TODO if perf. problems
          max_avatar_size = "200K";
          #retention # Politique de rétention de message si nécessaire (default false)

          # Media store
          max_upload_size = "200K";
          max_image_pixels = "4M";
          dynamic_thumbnails = false; # Resize en fonction des clients, voir si c'est utile...
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
              issuer = "https://idm.${network.domain}/oauth2/openid/matrix-synapse";
              client_id = "matrix-synapse";
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
            "turn:turn.${network.domain}:${toString coturn.listening-port}?transport=udp"
            "turn:turn.${network.domain}:${toString coturn.listening-port}?transport=tcp"
          ];
          turn_shared_secret_path = lib.mkIf hasTurn config.sops.secrets.turn-secret-matrix.path;
          turn_user_lifetime = lib.mkIf hasTurn "1h";
          turn_allow_guests = true; # Default... voir si false serait pas mieux.

          # TODO: https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html#registration
        };
      };
    })
  ];
}
