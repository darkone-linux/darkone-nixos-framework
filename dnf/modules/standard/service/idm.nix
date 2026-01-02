# Kanidm (identity manager) DNF Service.

{
  lib,
  dnfLib,
  network,
  host,
  zone,
  config,
  users,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.idm;
  srvPort = 8443;
  inherit (config.sops) secrets;
  isHcs = dnfLib.isHcs host zone network;
  isMainReplica = isHcs || !network.coordination.enable;
  defaultParams = {
    title = "Authentification";
    description = "Global authentication for DNF services";
    ip = "127.0.0.1";
    icon = "kanidm";
  };
  params = dnfLib.extractServiceParams host network "idm" defaultParams;
in
{
  options = {
    darkone.service.idm.enable = lib.mkEnableOption "Enable local SSO with Kanidm";
  };

  config = lib.mkMerge [

    #========================================================================
    # DNF Service configuration
    #========================================================================

    {
      darkone.system.services.service.idm = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/kanidm" ];
        proxy.enable = isMainReplica;
        proxy.servicePort = srvPort;
        proxy.scheme = "https";
        proxy.extraConfig = ''
          {
            transport http {
              tls_insecure_skip_verify
            }
            header_up Host {host}
          }
        '';
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.idm.enable = true;
      };

      # SMTP Relay
      darkone.service.postfix.enable = true;

      #========================================================================
      # Kanidm user & secrets
      #========================================================================

      # Kanidm secrets auths
      sops.secrets = builtins.listToAttrs (
        map
          (item: {
            name = item;
            value = {
              mode = "0400";
              owner = "kanidm";
            };
          })
          [
            "kanidm-idm-admin-password"
            "kanidm-admin-password"
            "kanidm-tls-chain"
            "kanidm-tls-key"
            "oidc-secret-forgejo"
            #"smtp/password"
          ]
      );

      #========================================================================
      # Kanidm service
      #========================================================================

      systemd.services.kanidmd.serviceConfig = lib.mkIf (!isHcs) {

        # On autorise l'accès en lecture aux chemins système vitaux
        # -> https://github.com/kanidm/kanidm/blob/392a10afbc19759d1431025a2daee0dd903b2733/examples/unixd#L77
        ReadOnlyPaths = [
          "/run/current-system/sw/bin"
          "/etc/profiles/per-user/nix/bin"
          "${pkgs.zsh}/bin"
        ];
      };

      # Sendmail permissions
      systemd.services.kanidm.path = [
        pkgs.postfix
        pkgs.coreutils
      ];

      #========================================================================
      # Kanidm instance
      #========================================================================

      # Kanidm main instance
      services.kanidm = {
        package = pkgs.kanidm_1_8.withSecretProvisioning;

        #----------------------------------------------------------------------
        # SERVER
        #----------------------------------------------------------------------

        # Gère la BD (Argon2id) et expose des interfaces API, Web + pont LDAP en lecture.
        # -> https://github.com/kanidm/kanidm/blob/master/examples/server.toml
        enableServer = true;
        serverSettings = {
          bindaddress = "${params.ip}:${toString srvPort}";

          # The domain that Kanidm manages. Must be below or equal to the domain specified in serverSettings.origin.
          # This can be left at null, only if your instance has the role ReadOnlyReplica.
          inherit (network) domain;

          # The origin of the Kanidm instance.
          origin = params.href;

          # Address and port the LDAP server is bound to. Setting this to null disables the LDAP interface.
          ldapbindaddress = lib.mkIf isMainReplica "${host.vpnIp}:636";

          # The role of this server. This affects the replication relationship and thereby available features.
          # -> N'existe pas dans la conf kanidm...
          role = if isMainReplica then "WriteReplica" else "WriteReplicaNoUI";

          # Internal TLS Certificates
          # openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=127.0.0.1";
          tls_chain = secrets.kanidm-tls-chain.path;
          tls_key = secrets.kanidm-tls-key.path;

          # TODO
          #replication = {};
        };

        #----------------------------------------------------------------------
        # CLIENT
        #----------------------------------------------------------------------

        # Web/CLI client
        enableClient = true;
        clientSettings = {
          uri = params.href;
        };

        #----------------------------------------------------------------------
        # UNIXD / PAM / NSS (WIP)
        #----------------------------------------------------------------------

        # Configuration du démon Unix pour PAM/NSS (remplace SSSD)
        enablePam = !isHcs;
        unixSettings = lib.mkIf (!isHcs) {
          default_shell = "/etc/profiles/per-user/nix/bin/zsh";
          pam_allowed_login_groups = [ "posix" ];
        };

        #----------------------------------------------------------------------
        # Provision
        #----------------------------------------------------------------------

        provision = {
          enable = true;

          # Determines whether deleting an entity in this provisioning config should automatically cause them to be removed from kanidm, too.
          # This works because the provisioning tool tracks all entities it has ever created.
          # If this is set to false, you need to explicitly specify present = false to delete an entity.
          autoRemove = true;
          adminPasswordFile = secrets.kanidm-admin-password.path;
          idmAdminPasswordFile = secrets.kanidm-idm-admin-password.path;
          groups = {
            posix = {
              present = true; # default
              members = lib.mapAttrsToList (name: _: name) users;

              # Optional. Defaults to true if not given.
              # Whether groups should be appended (false) or overwritten (true).
              # In append mode, members of this group can be managed manually in kanidm
              # in addition to members declared here, but removing a member from this state.json
              # will not remove the corresponding member from the group in kanidm! Removals have
              # to be reflected manually!
              overwriteMembers = true;
            };
            users.members = lib.mapAttrsToList (name: _: name) users;
            admins.members = lib.mapAttrsToList (name: _: name) (
              lib.filterAttrs (_: u: lib.any (g: g == "idm-admins") u.groups) users
            );
            devs.members = lib.mapAttrsToList (name: _: name) (
              lib.filterAttrs (_: u: lib.any (g: g == "idm-devs") u.groups) users
            );
          };

          #----------------------------------------------------------------------
          # Oauth2 provisioning
          #----------------------------------------------------------------------

          systems.oauth2 = {

            # TODO: automatiser
            # https://forgejo.org/docs/next/user/oauth2-provider/
            forgejo = {
              displayName = "Forgejo Git Service";

              # Application image to display in the WebUI.
              # Kanidm supports “image/jpeg”, “image/png”, “image/gif”, “image/svg+xml”, and “image/webp”.
              # The image will be uploaded each time kanidm-provision is run.
              # -> https://selfh.st/icons/
              imageFile = ./../../../assets/app-icons/forgejo.svg;

              # Enable legacy crypto on this client. Allows JWT signing algorthms like RS256.
              enableLegacyCrypto = false;

              # The redirect URL of the service. These need to exactly match the OAuth2 redirect target.
              originUrl = "https://git.${network.domain}/user/oauth2/idm/callback";
              originLanding = "https://git.${network.domain}/explore/repos";

              # https://forgejo.org/docs/next/user/oauth2-provider/#public-client-pkce
              allowInsecureClientDisablePkce = true;

              basicSecretFile = secrets.oidc-secret-forgejo.path;

              scopeMaps = {
                admins = [
                  "openid"
                  "email"
                  "profile"
                  "groups"
                ];
                devs = [
                  "openid"
                  "email"
                  "profile"
                  "groups"
                ];
              };

              claimMaps = {
                forgejo = {
                  valuesByGroup = {
                    admins = [ "darkone" ];
                    devs = [
                      "darkone"
                      "guest"
                    ];
                  };
                };
              };
            };
          };

          #----------------------------------------------------------------------
          # Users provisioning
          #----------------------------------------------------------------------

          persons = lib.mapAttrs (_: u: {
            present = true; # default
            displayName = u.name;
            mailAddresses = [ u.email ];
            groups = [ "posix" ];
          }) users;
        };
      };
    })
  ];
}
