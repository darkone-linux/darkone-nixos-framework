# A matrix (synapse) server. (WIP)

{
  lib,
  config,
  network,
  host,
  ...
}:
let
  inherit network;
  cfg = config.darkone.service.matrix;
  srv = config.services.matrix-synapse;
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
        defaultParams = {
          description = "Communication solution";
        };
        persist.dirs = [ srv.dataDir ];
        proxy.servicePort = (builtins.elemAt srv.settings.listeners 0).port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.matrix.enable = true;
      };

      #------------------------------------------------------------------------
      # Matrix service dependencies
      #------------------------------------------------------------------------

      # Tools
      #environment.systemPackages = with pkgs; [ ];

      # Matrix DB
      # services.postgresql = {
      #   enable = true;
      #   initialScript = pkgs.writeText "synapse-init.sql" ''
      #     CREATE ROLE "matrix-synapse" WITH LOGIN PASSWORD 'synapse';
      #     CREATE DATABASE "matrix-synapse" WITH OWNER "matrix-synapse"
      #       TEMPLATE template0
      #       LC_COLLATE = "C"
      #       LC_CTYPE = "C";
      #   '';
      # };

      #------------------------------------------------------------------------
      # Synapse Server
      #------------------------------------------------------------------------

      services.matrix-synapse = {
        enable = true;
        configureRedisLocally = false; # TODO: true
        # plugins = with config.services.matrix-synapse.package.plugins; [
        #   matrix-synapse-ldap3
        #   matrix-synapse-pam
        # ];
        settings = {
          server_name = network.domain;
          enable_metrics = false;
          enable_registration = false;
          dynamic_thumbnails = false;
          suppress_key_server_warning = true;
          listeners = [
            {
              port = 8008;
              bind_addresses = [ host.ip ];
              type = "http";
              tls = false;
              x_forwarded = true;
              resources = [
                {
                  names = [
                    "client"
                    "federation"
                  ];
                  compress = false;
                }
              ];
            }
          ];
          # database = {
          #   name = "psycopg2"; # PG python driver
          #   args = {
          #     user = "matrix-synapse";
          #     database = "matrix-synapse";
          #     cp_min = 5;
          #     cp_max = 10;
          #   };
          # };
        };
      };
    })
  ];
}
