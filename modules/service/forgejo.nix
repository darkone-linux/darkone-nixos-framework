# A full-configured forgejo git forge.

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
  cfg = config.darkone.service.forgejo;
  fjCfg = config.services.forgejo;
  srv = fjCfg.settings.server;
  params = dnfLib.extractServiceParams host network "forgejo" { };
in
{
  options = {
    darkone.service.forgejo.enable = lib.mkEnableOption "Enable local forgejo service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.forgejo = {
        persist.dirs = [
          "/var/lib/forgejo/custom"
          "/var/lib/forgejo/data"
          "/var/lib/forgejo/repositories"
        ];
        proxy.servicePort = srv.HTTP_PORT;
      };

      #----------------------------------------------------------------------
      # Kanidm OAuth2 client template (model for other services)
      #----------------------------------------------------------------------

      # https://forgejo.org/docs/next/user/oauth2-provider/
      darkone.service.idm.oauth2.forgejo = {

        # The service sub-domain is `git`, so the auto-derived client name
        # would be `forgejo-git`. We override it to keep the historical
        # `forgejo` identifier (and its matching `oidc-secret-forgejo` key).
        clientName = "forgejo";

        displayName = "Forgejo Git Service";

        # Application image to display in the WebUI.
        # Kanidm supports "image/jpeg", "image/png", "image/gif", "image/svg+xml", and "image/webp".
        # The image will be uploaded each time kanidm-provision is run.
        # -> https://selfh.st/icons/
        imageFile = ./../../assets/app-icons/forgejo.svg;

        # Enable legacy crypto on this client. Allows JWT signing algorithms like RS256.
        enableLegacyCrypto = false;

        # https://forgejo.org/docs/next/user/oauth2-provider/#public-client-pkce
        allowInsecureClientDisablePkce = false;

        # Path templates relative to params.href (https://git.<domain>).
        # idm.nix prefixes them with the resolved href to produce the final URLs.
        # These need to exactly match the OAuth2 redirect target on the consumer side.
        redirectPaths = [ "/user/oauth2/idm/callback" ];
        landingPath = "/user/oauth2/idm"; # Auto-connect entry point
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "forgejo";

      # SMTP Relay
      darkone.service.postfix.enable = true;

      # Sendmail permissions & service updates to send emails
      systemd.services.forgejo.path = [
        pkgs.postfix
        pkgs.coreutils
      ];
      systemd.services.forgejo.serviceConfig = {
        RestrictAddressFamilies = [ "AF_NETLINK" ];
        ReadWritePaths = [ "/var/spool/mail" ];
        ProtectSystem = lib.mkForce "full";
      };
      users.users.forgejo = {
        extraGroups = [ "postdrop" ];
      };

      #------------------------------------------------------------------------
      # Forgejo Service
      #------------------------------------------------------------------------

      services.forgejo = {
        enable = true;
        package = pkgs.forgejo;
        database.type = "postgres";
        lfs.enable = true;
        settings = {
          server = {
            DOMAIN = host.ip;
            ROOT_URL = params.href; # URL before reverse proxy
            HTTP_PORT = 3000;
            LANDING_PAGE = "explore";
          };
          DEFAULT = {
            APP_NAME = params.title;
          };
          #log.LEVEL = "Debug";

          # You can temporarily allow registration to create an admin user.
          service.DISABLE_REGISTRATION = false;
          service.SHOW_REGISTRATION_BUTTON = false;
          service.ALLOW_ONLY_EXTERNAL_REGISTRATION = true;
          "service.explore".DISABLE_USERS_PAGE = true;
          "service.explore".DISABLE_ORGANIZATIONS_PAGE = true;
          "ui.meta".AUTHOR = "Darkone Linux";
          "ui.meta".DESCRIPTION = params.description;

          # Add support for actions, based on act: https://github.com/nektos/act
          actions = {
            ENABLED = false;
            DEFAULT_ACTIONS_URL = "github";
          };

          openid = {
            ENABLE_OPENID_SIGNIN = false;
            ENABLE_OPENID_SIGNUP = true;
          };

          # TODO: declarative link to idm (currently must be done in the UI)
          oauth2_client = {
            ENABLE_AUTO_REGISTRATION = true;
          };
          mailer = {
            ENABLED = true;
            PROTOCOL = "sendmail";
            FROM = "noreply@${network.domain}";
            SENDMAIL_PATH = "${pkgs.system-sendmail}/bin/sendmail";
          };
          other = {
            SHOW_FOOTER_VERSION = false;
          };
        };
      };
    })
  ];
}
