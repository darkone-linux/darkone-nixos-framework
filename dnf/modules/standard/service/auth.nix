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
  autheliaRedisPort = 6380;
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
    darkone.service.auth.enable = lib.mkEnableOption "Enable local SSO with Authelia";
    darkone.service.auth.enableLdapBackend = lib.mkEnableOption "Enable the LLDAP backend with Authelia";
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

      # Redis for sessions
      services.redis.servers.authelia = {
        enable = true;
        port = autheliaRedisPort;
        bind = "127.0.0.1";
        requirePass = null; # Local access only
      };

      #------------------------------------------------------------------------
      # Authelia Service
      #------------------------------------------------------------------------

      # Authelia service configuration
      systemd.services.authelia-main =
        let
          dependencies = [
            "lldap.service"
            "postgresql.service"
            "redis.service"
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
        # TODO: générer ça automatiquement en oneshot...
        secrets = {

          # The secret key used to sign and verify the JWT.
          # -> identity_validation.reset_password.jwt_secret
          jwtSecretFile = config.sops.secrets.authelia-jwt_secret.path;

          ## The JWK's issuer option configures multiple JSON Web Keys. It's required that at least one of the JWK's
          ## configured has the RS256 algorithm. For RSA keys (RS or PS) the minimum is a 2048 bit key.
          # La clé privée RSA qui sert à signer mathématiquement vos jetons d'accès (JWT) afin que les
          # applications puissent vérifier, grâce à la clé publique correspondante, qu'ils sont
          # authentiques et n'ont pas été modifiés.
          # -> identity_providers.oidc.jwks[].key
          # openssl genrsa -out private.pem 2048
          oidcIssuerPrivateKeyFile = config.sops.secrets.authelia-jwks.path;

          # The hmac_secret is used to sign OAuth2 tokens (authorization code, access tokens and refresh tokens).
          # -> identity_providers.oidc.hmac_secret
          oidcHmacSecretFile = config.sops.secrets.authelia-hmac_secret.path;

          # The secret to encrypt the session data. This is only used with Redis / Redis Sentinel.
          sessionSecretFile = config.sops.secrets.authelia-session_secret.path;

          # La clé de chiffrement utilisée pour chiffrer les informations sensibles dans la base de données.
          # Elle doit être une chaîne de caractères d'une longueur minimale de 20. Pour changer cette clé, il faut
          # utiliser l'outil cli obligatoirement pour garder les données : authelia storage encryption change-key.
          storageEncryptionKeyFile = config.sops.secrets.authelia-storage_encryption_key.path;
        };

        # TODO: utiliser un password différent pour l'authentification Authelia -> LLDAP
        environmentVariables = lib.mkIf cfg.enableLdapBackend {
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

          authentication_backend = {
            password_change.disable = true;
            password_reset.disable = true;

            # LLDAP Backend (dynamic users)
            ldap = lib.mkIf cfg.enableLdapBackend {
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

            # File backend (static users)
            file = {
              path = "";
              watch = false;
              search = {
                email = true;
                case_insensitive = true;
              };
            };

          };

          session = {

            # Default cookie name
            name = "dnf_auth";

            # The period of time before the cookie expires and the session is destroyed
            expiration = "3M";

            # The period of time the user can be inactive for before the session is destroyed
            inactivity = "1M";

            # The period of time before the cookie expires and the session is destroyed
            # when the remember me box is checked
            remember_me = "1y";

            cookies = [
              {
                domain = params.fqdn;
                authelia_url = params.href;
                #default_redirection_url = "https://${host.networkDomain}";
              }
            ];

            # TODO: Redis partagé pour sessions partagées ? Sentinel ? (non dispo sous nixos pour le moment)
            redis = {
              host = "127.0.0.1";
              port = autheliaRedisPort;
            };
          };

          # TODO: changer par postgres pour du HA ?
          storage.local.path = "/var/lib/authelia-main/db.sqlite3";

          # One factor par défaut
          access_control = {
            default_policy = "deny";
            rules = [
              {
                domain = "*.${params.fqdn}";
                policy = "one_factor";
              }
            ];
          };

          identity_providers.oidc = {

            # https://github.com/authelia/authelia/blob/master/config.template.yml#L1378
            clients = [
              {
                client_id = "forgejo";
                client_name = "Forgejo";

                # The client secret is a shared secret between Authelia and the consumer of this client.
                # Hash du secret à générer : nix-shell -p authelia --run "authelia crypto hash generate argon2"
                # -> sops: authelia-default-app-pwd
                client_secret = "$argon2id$v=19$m=65536,t=3,p=4$ygJHfShX4PFn5Ej2WReoqQ$GQ0NGPWC+HREQ6Scu5Gz48kfMnZjZLUbhAndASvnTPw";

                authorization_policy = "one_factor";

                # Redirect URI's specifies a list of valid case-sensitive callbacks for this client.
                redirect_uris = [ "https://git.${network.domain}/user/oauth2/dex/callback" ];
                scopes = [
                  "openid"
                  "groups"
                  "email"
                  "profile"
                ];
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
