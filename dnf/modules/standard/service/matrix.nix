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

          # Redirection vers Synapse
          reverse_proxy /_matrix/* http://127.0.0.1:8008
          reverse_proxy /_synapse/client/* http://127.0.0.1:8008

          # Aide les clients mobiles à trouver le serveur
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
      sops.secrets.oidc-secret-matrix-synapse = { };
      sops.templates.oidc-secret-synapse = {
        content = config.sops.placeholder.oidc-secret-matrix-synapse;
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
        configureRedisLocally = false; # TODO: true

        # https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html
        settings = {
          server_name = network.domain;
          public_baseurl = params.href;
          max_upload_size = "10M";
          enable_metrics = false;
          enable_registration = false;
          dynamic_thumbnails = false;
          suppress_key_server_warning = true;
          registration_shared_secret_path = config.sops.secrets.matrix-rss-password.path;
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
          database.args = {
            user = "matrix-synapse";
            database = "matrix-synapse";
          };
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
        };
      };
    })
  ];
}
