# DNF SSO with Authelia.

{
  lib,
  dnfLib,
  network,
  host,
  config,
  ...
}:
let
  cfg = config.darkone.service.auth;
  lldapSettings = config.services.lldap.settings;
  autheliaPort = 9091;
  defaultParams = {
    title = "Authentification";
    description = "Global authentication for DNF services";
    icon = "authelia";
    ip = "127.0.0.1";
  };
  params = dnfLib.extractServiceParams host network "auth" defaultParams;

  # On ne peut pas aller chercher ça dans 'params' quand on l'utilise dans
  # extraGlobalConfig car ce dernier est utilisé pour construire les params...
in
{
  options = {
    darkone.service.auth.enable = lib.mkEnableOption "Enable local SSO with Authelia (and LLDAP)";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.auth = {
        inherit defaultParams;
        persist.dirs = [
          "/etc/authelia"
          "/var/lib/authelia-main"
        ];
        proxy.servicePort = autheliaPort;

        # A Caddy snippet that can be imported to enable Authelia in front of a service
        # Cf. https://www.authelia.com/integration/proxies/caddy/#subdomain
        # forward_auth ${authServiceFqdn} {
        # NE MARCHE PAS -> forward_auth doit se faire sur le même serveur caddy...
        # proxy.extraGlobalConfig = ''
        #   (auth) {
        #     forward_auth ${authServiceFqdn} {
        #       uri /api/authz/forward-auth
        #       copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
        #     }
        #   }
        # '';
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.auth.enable = true;
      };

      #------------------------------------------------------------------------
      # Authelia user & secrets
      #------------------------------------------------------------------------

      # Require users service
      darkone.service.users.enable = true;

      # Access to default password (main instance)
      users.users.authelia-main = {
        isSystemUser = true;
        group = "authelia-main";
        extraGroups = [ "sops" ];
      };
      users.groups.authelia-main = { };

      # Authelia secrets auths
      # WARNING: Authelia DO NOT UPDATE theses keys if we change it (for the moment)
      sops.secrets = builtins.listToAttrs (
        map
          (item: {
            name = item;
            value = {
              mode = "0400";
              owner = "authelia-main";
              group = "authelia-main";
            };
          })
          [
            "authelia-jwt_secret"
            "authelia-jwks"
            "authelia-hmac_secret"
            "authelia-session_secret"
            "authelia-storage_encryption_key"
            "smtp/address"
            "smtp/username"
            "smtp/password"
            "smtp/sender"
          ]
      );

      # Construction d'un fichier de configuration pour les données SMTP
      sops.templates."authelia-main-smtp.yml" = {
        content = ''
          notifier:
            smtp:
              address: '${config.sops.placeholder."smtp/address"}'
              username: '${config.sops.placeholder."smtp/username"}'
              password: '${config.sops.placeholder."smtp/password"}'
              sender: '${config.sops.placeholder."smtp/sender"}'
        '';
        owner = "authelia-main";
      };

      #------------------------------------------------------------------------
      # Related services
      #------------------------------------------------------------------------

      # Sauvegarde postgresql (par défaut toutes les bases)
      services.postgresqlBackup.enable = true;

      #------------------------------------------------------------------------
      # Authelia Service
      #------------------------------------------------------------------------

      # Authelia service configuration
      systemd.services.authelia-main =
        let
          dependencies = [
            "lldap.service"
            "postgresql.service"
            # "redis.service"
          ];
        in
        {
          # Authelia requires LLDAP, PostgreSQL, (TODO: and Redis) to be running
          after = dependencies;
          requires = dependencies;

          # Templating activation (for OIDC)
          serviceConfig.Environment = "X_AUTHELIA_CONFIG_FILTERS=template";
        };

      # Authelia main instance
      services.authelia.instances.main = {
        enable = true;

        # Générer et mettre ces secrets dans secrets.yaml
        # Pour jwks : openssl genrsa -out authelia-oidc-private-key.pem 4096
        # Pour les autres : openssl rand -base64 32
        # TODO: générer ça automatiquement
        secrets = {
          jwtSecretFile = config.sops.secrets.authelia-jwt_secret.path;

          # TODO: OpenID
          #oidcIssuerPrivateKeyFile = config.sops.secrets.authelia-jwks.path;
          #oidcHmacSecretFile = config.sops.secrets.authelia-hmac_secret.path;

          sessionSecretFile = config.sops.secrets.authelia-session_secret.path;
          storageEncryptionKeyFile = config.sops.secrets.authelia-storage_encryption_key.path;
        };

        # TODO: utiliser un password différent pour l'authentification Authelia -> LLDAP
        environmentVariables = {
          AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE = config.sops.secrets.default-password.path;
        };

        # Conf SMTP
        settingsFiles = [ config.sops.templates."authelia-main-smtp.yml".path ];

        # https://www.authelia.com/configuration/
        settings = {
          theme = "auto";
          log.level = "info";

          server = {
            address = "tcp://${params.ip}:${toString autheliaPort}/";
            endpoints = {
              authz = {
                forward-auth = {
                  implementation = "ForwardAuth";
                };
              };
            };
          };

          authentication_backend.ldap = {
            implementation = "lldap";
            address = "ldap://${lldapSettings.ldap_host}:${toString lldapSettings.ldap_port}";
            base_dn = lldapSettings.ldap_base_dn;
            user = "uid=admin,ou=people,${lldapSettings.ldap_base_dn}"; # Bind user
            users_filter = "(&({username_attribute}={input})(objectClass=person))";
            groups_filter = "(&(member={dn})(objectClass=groupOfNames))";
            additional_users_dn = "ou=people";
            additional_groups_dn = "ou=groups";
            attributes = {
              distinguished_name = "dn";
              username = "uid";
              mail = "mail";
              display_name = "cn";
              family_name = "sn"; # = last_name
              given_name = "first_name";
            };
            start_tls = false; # TODO: true
            tls = {
              skip_verify = true; # For tests
              minimum_version = "TLS1.2";
            };
          };

          session = {
            expiration = "1h";
            inactivity = "5m";
            cookies = [
              {
                name = "dnf_auth";
                domain = params.fqdn;
                authelia_url = params.href;
                #default_redirection_url = "https://${host.networkDomain}";

                # The period of time the user can be inactive for before the session is destroyed
                inactivity = "1M";

                # The period of time before the cookie expires and the session is destroyed
                expiration = "3M";

                # The period of time before the cookie expires and the session is destroyed
                # when the remember me box is checked
                remember_me = "1y";
              }
            ];
          };
          storage.local.path = "/var/lib/authelia-main/db.sqlite3";

          access_control = {
            default_policy = "deny";
            rules = [
              {
                domain = "*.${params.fqdn}";
                policy = "one_factor";
              }
            ];
          };

          # If no SMTP
          # notifier.filesystem.filename = "/var/lib/authelia-main/notification.txt";
        };
      };
    })
  ];
}
