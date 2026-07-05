# Nextcloud full-configured service.
#
# :::caution[Required sops secret]
# When enabled, this module reads the Nextcloud admin password from the sops
# secret `nextcloud-admin-password`. Add the entry to `usr/secrets/` before
# rebuilding, otherwise sops-nix activation will fail.
# :::

{
  lib,
  config,
  pkgs,
  zone,
  network,
  host,
  hosts,
  dnfLib,
  dnfConfig,
  ...
}:
let
  cfg = config.darkone.service.nextcloud;
  srv = config.services.nextcloud;
  port = dnfConfig.network.ports.nextcloud;
  defaultParams = {
    description = "Local personal cloud";
  };
  params = dnfLib.extractServiceParams host network "nextcloud" defaultParams;

  inherit
    (dnfLib.mkOidcContext {
      name = "nextcloud";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;

  # No Kanidm on this network ⇒ skip the user_oidc provisioning.
  hasIdm = idmUrl != null;

  # Apps fetched from the appstore and bundled by nixpkgs, i.e. every
  # package under `services.nextcloud.package.packages.apps` for this
  # release. Installed (and occ-enabled) only when listed in `cfg.plugins`.
  appstoreApps = [
    "bookmarks"
    "calendar"
    "checksum"
    "collectives"
    "contacts"
    "cookbook"
    "cospend"
    "dav_push"
    "deck"
    "end_to_end_encryption"
    "files_automatedtagging"
    "files_linkeditor"
    "files_retention"
    "forms"
    "gpoddersync"
    "groupfolders"
    "guests"
    "hmr_enabler"
    "impersonate"
    "integration_deepl"
    "integration_openai"
    "integration_paperless"
    "mail"
    "memories"
    "music"
    "news"
    "nextpod"
    "notes"
    "notify_push"
    "oidc"
    "oidc_login"
    "onlyoffice"
    "phonetrack"
    "polls"
    "previewgenerator"
    "qownnotesapi"
    "quota_warning"
    "recognize"
    "registration"
    "repod"
    "richdocuments"
    "sociallogin"
    "spreed"
    "tables"
    "tasks"
    "theming_customcss"
    "twofactor_webauthn"
    "unroundedcorners"
    "uppush"
    "user_oidc"
    "user_saml"
    "whiteboard"
  ];

  # Apps shipped inside Nextcloud core (`core/shipped.json`) that are
  # enabled out of the box but safe to turn off (unlike e.g. `files_sharing`
  # or `password_policy`, which stay untouched). Toggled via `occ
  # app:enable|disable` below since they never go through `extraApps`.
  shippedToggleableApps = [
    "activity"
    "dashboard"
    "photos"
  ];
in
{
  options = {
    darkone.service.nextcloud.enable = lib.mkEnableOption "Enable local nextcloud service";
    darkone.service.nextcloud.adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Admin username for Nextcloud";
    };
    darkone.service.nextcloud.plugins = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (appstoreApps ++ shippedToggleableApps));
      default = [
        "calendar"
        "contacts"
      ];
      example = appstoreApps ++ shippedToggleableApps;
      description = ''
        Nextcloud apps to enable. Only `calendar` and `contacts` are on by
        default; Talk (`spreed`), the dashboard, activity feed, photos, and
        every other app stay disabled until listed here.

        `user_oidc` is required for Kanidm SSO and is force-included
        regardless of this list.
      '';
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.nextcloud = {
        inherit defaultParams;
        persist = {
          dirs = [ srv.home ];
          dbDirs = [ config.services.postgresql.dataDir ];
          varDirs = [ "/var/lib/redis-nextcloud" ];
        };
        proxy.servicePort = port;

        # X-Content-Type-Options: nosniff -> Prevents the browser from guessing the MIME type.
        # Referrer-Policy: no-referrer-when-downgrade -> Do not send the Referer header when downgrading from HTTPS -> HTTP
        # (X-Frame-Options / X-Robots-Tag / Strict-Transport-Security come from the helper.)
        proxy.extraConfig = dnfLib.mkCaddySecurityHeaders {
          maxUploadSize = "200MB";
          extraHeaders = ''
            X-Content-Type-Options "nosniff"
            Referrer-Policy "no-referrer-when-downgrade"
          '';
        };
      };

      # Kanidm OAuth2 client template. Consumer side is wired declaratively
      # below via the first-party `user_oidc` app, provisioned with `occ`.
      darkone.service.idm.oauth2.nextcloud = {
        displayName = "Nextcloud";
        imageFile = ./../../assets/app-icons/nextcloud.svg;

        # user_oidc callbacks (code flow). `/login` is the post-auth landing.
        redirectPaths = [
          "/login"
          "/apps/user_oidc/code"
          "/apps/user_oidc/login"
        ];
        landingPath = "/";

        # user_oidc negotiates PKCE automatically when the provider supports
        # it (Kanidm does), so keep PKCE enforced on this client.
        allowInsecureClientDisablePkce = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "nextcloud";

      #------------------------------------------------------------------------
      # Nextcloud dependencies
      #------------------------------------------------------------------------

      # Initial admin password, provisioned from sops.
      # The corresponding entry must exist in usr/secrets/.
      sops.secrets."nextcloud-admin-password" = {
        mode = "0400";
        owner = "nextcloud";
      };

      # Re-encrypted alias of the kanidm-owned OAuth2 secret, read by the
      # `occ` provisioning unit (runs as the nextcloud user) via
      # `--clientsecret-file`, so the secret stays out of argv and the store.
      sops.secrets."${secret}-service" = lib.mkIf hasIdm {
        mode = "0400";
        owner = "nextcloud";
        key = secret;
      };

      # Internal nginx
      services.nginx = {
        virtualHosts."${params.fqdn}" = {
          listen = [
            {
              addr = params.ip;
              inherit port;
            }
          ];
        };
      };

      # nginx binds a specific host address that may be momentarily absent
      # while the network stack is reconfigured during a nixos-rebuild switch.
      # Non-local bind lets the listener come up regardless, instead of dying
      # with "cannot assign requested address" at every fleet deployment.
      boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

      # Whiteboard server (TODO: automatiser)
      # nextcloud-occ config:app:set whiteboard collabBackendUrl --value="${params.href}"
      # nextcloud-occ config:app:set whiteboard jwt_secret_key --value="test123"
      services.nextcloud-whiteboard-server = {
        enable = true;
        settings.NEXTCLOUD_URL = params.href;
        secrets = [ "/etc/nextcloud-whiteboard-secret" ];
      };
      environment.etc."nextcloud-whiteboard-secret".text = ''
        JWT_SECRET_KEY=test123
      '';

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = dnfLib.mkInternalFirewall host zone [ port ];

      #------------------------------------------------------------------------
      # Nextcloud Service
      #------------------------------------------------------------------------

      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud33;
        hostName = params.fqdn;
        maxUploadSize = "16G";
        https = false;

        # TODO: https://search.nixos.org/options?channel=unstable&show=services.nextcloud.secrets
        #secrets = {};

        # Configuration de base
        config = {
          adminuser = cfg.adminUser;
          adminpassFile = config.sops.secrets."nextcloud-admin-password".path;
          dbtype = "pgsql";
        };

        # PostgreSQL database
        database.createLocally = true;

        # Configuration PHP et cache
        phpOptions = {
          "opcache.interned_strings_buffer" = "64";
          "opcache.max_accelerated_files" = "10000";
          "opcache.memory_consumption" = "256";
          "opcache.revalidate_freq" = "1";
          "opcache.fast_shutdown" = "1";
        };

        # Cache Redis
        configureRedis = true;

        # Disable app store
        appstoreEnable = false;

        # Default applications
        # `user_oidc` is force-included (required for Kanidm SSO); other
        # apps come from `cfg.plugins`, intersected with the appstore
        # catalogue so shipped-only entries (e.g. `photos`) are ignored here.
        extraApps =
          let
            inherit (config.services.nextcloud.package.packages) apps;
            enabled = lib.unique (lib.intersectLists cfg.plugins appstoreApps ++ [ "user_oidc" ]);
          in
          lib.genAttrs enabled (name: apps.${name});

        # Apps config
        autoUpdateApps.enable = true;

        # Client Push
        # TODO: separate service, accessible via HTTPS
        #notify_push.enable = true;

        # Additional settings
        settings = {
          overwriteprotocol = "https";

          # user_oidc fetches the OIDC discovery doc back-channel from the idm
          # host, which resolves to a tailnet IP (100.64.0.0/10). Nextcloud's
          # SSRF guard (DnsPinMiddleware) blocks local/private targets by
          # default; allow them so OIDC discovery succeeds on the VPN.
          allow_local_remote_servers = lib.mkIf hasIdm true;
          trusted_domains = [
            "localhost"
            params.domain
            params.fqdn
          ];
          trusted_proxies = [
            "10.64.0.0/10"
            "10.0.0.0/8"
            "127.0.0.1"
            "::1"
          ];
          default_phone_region = lib.toUpper (builtins.substring 3 2 zone.locale);

          # SMTP params
          # Only works if the admin email address is set in their account!
          mail_domain = network.domain;
          mail_smtpmode = "smtp";
          mail_sendmailmode = "smtp";
          mail_smtpport = network.smtp.port or 25;
          mail_smtpname = network.smtp.username or "";
          mail_smtphost = network.smtp.server or "";
          mail_smtpauth = true;
          mail_smtpsecure = lib.optionalString network.smtp.tls "ssl";
          mail_smtptimeout = 30;
          mail_from_address = "noreply";
        };
      };

      # Ensure PostgreSQL and Redis are enabled
      # TODO: enable services.postgresqlBackup
      services.postgresql.enable = lib.mkDefault true;
      services.redis.servers.nextcloud.enable = lib.mkDefault true;

      # PostgreSQL backup (all databases by default)
      services.postgresqlBackup.enable = true;

      #------------------------------------------------------------------------
      # Shipped app toggles (dashboard, activity, photos...)
      #------------------------------------------------------------------------

      # `occ app:enable|disable` is an upsert, so this is idempotent: it
      # re-asserts the desired state (from `cfg.plugins`) on every activation,
      # since these apps ship enabled by default and aren't part of `extraApps`.
      systemd.services.nextcloud-plugins-setup = {
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "nextcloud";
        };
        script = lib.concatMapStringsSep "\n" (
          name:
          "${lib.getExe config.services.nextcloud.occ} app:${
            if lib.elem name cfg.plugins then "enable" else "disable"
          } ${name}"
        ) shippedToggleableApps;
      };

      #------------------------------------------------------------------------
      # OIDC provider (Kanidm, via the first-party user_oidc app)
      #------------------------------------------------------------------------

      # `user_oidc:provider <id>` is an upsert, so this is idempotent: it
      # creates the "IDM" provider on first boot and updates it afterwards.
      # Runs as the nextcloud user (occ wrapper expects it); the client secret
      # is read from the sops alias file, never passed on the command line.
      systemd.services.nextcloud-oidc-setup = lib.mkIf hasIdm {
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "nextcloud";
        };
        script = ''
          ${lib.getExe config.services.nextcloud.occ} user_oidc:provider IDM \
            --clientid=${clientId} \
            --clientsecret-file=${config.sops.secrets."${secret}-service".path} \
            --discoveryuri=${oidc.openidConfigUrl} \
            --scope="openid email profile" \
            --unique-uid=0 \
            --mapping-uid=preferred_username \
            --mapping-email=email \
            --mapping-display-name=name
        '';
      };
    })
  ];
}
