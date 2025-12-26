# A full-configured keycloak IAM service.

{
  lib,
  dnfLib,
  config,
  network,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.keycloak;
  params = dnfLib.extractServiceParams host network "keycloak" { };
  srvPort = 38080;
  isGateway =
    lib.attrsets.hasAttrByPath [ "gateway" "hostname" ] zone && host.hostname == zone.gateway.hostname;

  # TODO: Realm déclaratif
  # Eventuellement avec -> https://github.com/adorsys/keycloak-config-cli
  # realmFile = pkgs.writeText "home-realm.json" (builtins.toJSON {
  #   realm = "home";
  #   enabled = true;
  #   users = [
  #     {
  #       username = "alice";
  #       enabled = true;
  #       email = "alice@example.com";
  #       credentials = [{
  #         type = "password";
  #         value = "superpass";
  #       }];
  #     }
  #   ];
  #   clients = [
  #     {
  #       clientId = "nextcloud";
  #       publicClient = false;
  #       secret = "XYZ";
  #       redirectUris = [ "https://nextcloud.example.com/*" ];
  #     }
  #   ];
  # });

in
{
  options = {
    darkone.service.keycloak.enable = lib.mkEnableOption "Enable keycloak service";
    darkone.service.keycloak.enableBootstrap = lib.mkEnableOption "Enable bootstrap state to set admin password";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.keycloak = {
        persist.dirs = [ "/var/lib/keycloak" ];
        proxy.servicePort = srvPort;
        proxy.extraConfig = ''
          header {
            X-Forwarded-Host {host}
            X-Forwarded-Proto {scheme}
          }
        '';
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.keycloak.enable = true;
      };

      #------------------------------------------------------------------------
      # Keycloak dependencies
      #------------------------------------------------------------------------

      # Sops DB password file
      sops.secrets = {
        keycloak-db-pass = {
          mode = "0400";
          owner = "postgres";
          restartUnits = [ "keycloak.service" ];
        };
      };

      # S'assurer que le service d'init attend que sops soit prêt
      systemd.services.keycloakPostgreSQLInit = {
        after = [ "sops-nix.service" ];
        wants = [ "sops-nix.service" ];
      };

      #------------------------------------------------------------------------
      # Related services
      #------------------------------------------------------------------------

      # Sauvegarde postgresql (par défaut toutes les bases)
      services.postgresqlBackup.enable = true;

      #------------------------------------------------------------------------
      # Keycloak Service
      #------------------------------------------------------------------------

      # Main service
      services.keycloak = {
        enable = true;
        initialAdminPassword = "changeme";
        database = {
          type = "postgresql";
          createLocally = true;
          username = "keycloak";
          passwordFile = config.sops.secrets.keycloak-db-pass.path;
        };

        # https://www.keycloak.org/server/all-config?f=config
        settings = {
          hostname = params.fqdn;
          http-host = if cfg.enableBootstrap then "0.0.0.0" else params.ip;
          http-port = srvPort;
          proxy-headers = "xforwarded";
          proxy-trusted-addresses = zone.gateway.lan.ip;
          http-enabled = true;

          # TODO: Full-declarative keycloak configuration
          # features = "<name>[,<name>]";
          # features-disabled = "<name>[,<name>]";
          #
          # # https://www.keycloak.org/server/importExport
          # # Limite: on ne peut peut-être pas écraser une conf existante...
          # # cf. plus haut
          # import-realm = "path/to/generated/realm.json";
        };
      };

      # Open service port, only for lan0 on gateway
      networking.firewall =
        if isGateway then
          { interfaces.lan0.allowedTCPPorts = [ srvPort ]; }
        else
          { allowedTCPPorts = [ srvPort ]; };
    })
  ];
}
