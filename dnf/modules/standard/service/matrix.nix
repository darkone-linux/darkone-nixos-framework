# A matrix (synapse) server.

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
      # Dependencies
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
      sops.secrets.turn-secret = lib.mkIf hasTurn { };
      sops.templates."synapse-extra-config.yml" = lib.mkIf hasTurn {
        content = ''
          turn_shared_secret: ${config.sops.placeholder.turn-secret}
        '';
        mode = "0400";
        owner = "matrix-synapse";
      };

      #------------------------------------------------------------------------
      # Matrix Synapse DB creation
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

      #------------------------------------------------------------------------
      # Related services
      #------------------------------------------------------------------------

      # Sauvegarde postgresql (par défaut toutes les bases)
      services.postgresqlBackup.enable = true;

      #------------------------------------------------------------------------
      # Synapse Server
      #------------------------------------------------------------------------

      services.matrix-synapse = {
        enable = true;
        configureRedisLocally = true;
        extraConfigFiles = lib.optional hasTurn config.sops.templates."synapse-extra-config.yml".path;

        # https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html
        settings = {

          # Généralités
          server_name = network.domain;
          public_baseurl = params.href;
          max_upload_size = "10M";
          enable_metrics = false;
          enable_registration = false;
          dynamic_thumbnails = false;
          suppress_key_server_warning = true;
          registration_shared_secret_path = config.sops.secrets.matrix-rss-password.path;
          auto_join_rooms = [ ]; # TODO
          listeners = [
            {
              port = synapsePort;
              bind_addresses = [ params.ip ];
              type = "http";
              tls = false;
              x_forwarded = true;
              resources = [
                {
                  # + "federation"
                  names = [ "client" ];
                  compress = true;
                }
              ];
            }
          ];

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
          turn_shared_secret = lib.mkIf hasTurn "ton-secret-turn";
          turn_user_lifetime = lib.mkIf hasTurn "1h";

          # # Fédération
          # federation_enabled = true; # Fédération activée (obligatoire pour les DM)
          # enable_room_list_search = false; # Interdit la découverte de mes salons salons
          # default_room_version = "10"; # Force les salons à ne jamais être fédérés par défaut
          # limit_remote_rooms = {
          #   # Interdire aux utilisateurs locaux de rejoindre des salons distants
          #   enabled = true;
          #   complexity = 0;
          # };
          # federation_domain_whitelist = [
          #   # Restreindre la fédération aux seuls serveurs autorisés
          #   "matrix.org"
          #   "exemple.org"
          # ];
          # federation_ip_range_blacklist = [
          #   # Interdire les IP littérales en fédération
          #   "0.0.0.0/8"
          #   "10.0.0.0/8"
          #   "100.64.0.0/10"
          #   "127.0.0.0/8"
          #   "169.254.0.0/16"
          #   "172.16.0.0/12"
          #   "192.0.0.0/24"
          #   "192.168.0.0/16"
          #   "198.18.0.0/15"
          #   "224.0.0.0/4"
          #   "::1/128"
          #   "fc00::/7"
          #   "fe80::/10"
          # ];
          # allow_guest_access = false; # Pas de comptes invités
        };
      };
    })
  ];
}
