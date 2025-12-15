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
  };
  params = dnfLib.extractServiceParams host network "auth" defaultParams;
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
        proxy.enable = false; # tmp
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.auth.enable = true;
      };

      #------------------------------------------------------------------------
      # Authelia user
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
        secrets.jwtSecretFile = "/etc/authelia/jwtsecret";
        secrets.storageEncryptionKeyFile = "/etc/authelia/encryptionkey";
        environmentVariables = {
          AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE = config.sops.secrets.default-password.path;
        };

        settings = {
          theme = "auto";
          log.level = "info";

          server = {
            address = "tcp://:${toString autheliaPort}/";
            # tls = {
            #   key = "/etc/authelia/certs/authelia.key";
            #   certificate = "/etc/authelia/certs/authelia.crt";
            # };
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
            address = "ldap://${params.fqdn}:${toString lldapSettings.ldap_port}";
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
            secret = "un_secret_session_test";
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

          notifier.filesystem.filename = "/var/lib/authelia-main/notification.txt";
          # notifier.smtp = {
          #   address = "smtp://TODO";
          #   username = "TODO";
          #   sender = "${params.domain}@${network.domain}";
          # };
        };
      };

      #------------------------------------------------------------------------
      # Caddy Service
      #------------------------------------------------------------------------

      # TODO: transférer vers caddy main
      services.caddy = {
        enable = true;

        virtualHosts."${params.fqdn}" = {
          extraConfig = ''
            tls /etc/authelia/certs/authelia.crt /etc/authelia/certs/authelia.key
            reverse_proxy 127.0.0.1:${toString autheliaPort}
          '';
        };

        # A Caddy snippet that can be imported to enable Authelia in front of a service
        # Cf. https://www.authelia.com/integration/proxies/caddy/#subdomain
        extraConfig = ''
          (auth) {
            forward_auth 127.0.0.1:${toString autheliaPort} {
              uri /api/authz/forward-auth
              copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
            }
          }
        '';

        virtualHosts."test-app.${params.fqdn}" = {
          extraConfig = ''
            import auth
            tls /etc/authelia/certs/test-app.crt /etc/authelia/certs/test-app.key
            reverse_proxy 127.0.0.1:3000
          '';
        };
      };

      # Networking (TMP)
      networking.firewall = {
        allowedTCPPorts = [ 443 ];
        interfaces.lan0.allowedTCPPorts = [ autheliaPort ];
      };
    })
  ];
}
