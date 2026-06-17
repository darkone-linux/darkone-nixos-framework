# A full-configured forgejo git forge.

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  network,
  host,
  hosts,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.forgejo;
  fjCfg = config.services.forgejo;
  srv = fjCfg.settings.server;
  params = dnfLib.extractServiceParams host network "forgejo" { };

  # OIDC context. The historical client name (`forgejo`) is preserved via the
  # template override; mirror it here so clientId/secret/endpoints match the
  # provisioned Kanidm client.
  inherit
    (dnfLib.mkOidcContext {
      name = "forgejo";
      clientName = "forgejo";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;

  # No Kanidm on this network ⇒ skip the OIDC auth-source provisioning.
  hasIdm = idmUrl != null;
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
      # OIDC auth source (Kanidm)
      #------------------------------------------------------------------------

      # Re-encrypted alias of the kanidm-owned OAuth2 secret, readable by the
      # forgejo user that runs the provisioning CLI below.
      sops.secrets."${secret}-service" = lib.mkIf hasIdm {
        mode = "0400";
        owner = fjCfg.user;
        key = secret;
      };

      # Forgejo exposes no declarative NixOS option for OAuth2 auth sources, so
      # we provision one idempotently via its admin CLI. Runs after the main
      # service (DB ready); add-on first boot, update on every later run.
      systemd.services.forgejo-oauth-setup = lib.mkIf hasIdm {
        description = "Provision Forgejo OIDC auth source (Kanidm)";
        after = [ "forgejo.service" ];
        requires = [ "forgejo.service" ];
        wantedBy = [ "multi-user.target" ];

        # The CLI resolves its config/data from these (same as forgejo.service).
        environment = {
          GITEA_WORK_DIR = fjCfg.stateDir;
          GITEA_CUSTOM = fjCfg.customDir;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = fjCfg.user;
          Group = fjCfg.group;
        };
        script = ''
          set -eu

          secret=$(${pkgs.coreutils}/bin/cat ${config.sops.secrets."${secret}-service".path})
          bin=${fjCfg.package}/bin/gitea

          # Reuse the existing "idm" source if present (update), else create it.
          if "$bin" admin auth list | ${pkgs.gnugrep}/bin/grep -qw idm; then
            id=$("$bin" admin auth list | ${pkgs.gawk}/bin/awk '$2=="idm"{print $1}')
            "$bin" admin auth update-oauth --id "$id" \
              --provider openidConnect --key ${clientId} --secret "$secret" \
              --auto-discover-url ${oidc.openidConfigUrl} --scopes "openid email profile"
          else
            "$bin" admin auth add-oauth --name idm \
              --provider openidConnect --key ${clientId} --secret "$secret" \
              --auto-discover-url ${oidc.openidConfigUrl} --scopes "openid email profile"
          fi
        '';
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
            HTTP_PORT = dnfConfig.network.ports.forgejo;
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

          # The OIDC auth source itself is provisioned declaratively by the
          # `forgejo-oauth-setup` oneshot below (Forgejo has no native NixOS
          # option for it). Auto-register links Kanidm logins to new accounts.
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
