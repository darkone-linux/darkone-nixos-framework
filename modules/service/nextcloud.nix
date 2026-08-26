# Nextcloud full-configured service.
#
# :::caution[Required sops secrets]
# When enabled, this module reads two sops secrets:
#
# - `nextcloud-admin-password`: initial password of the admin account;
# - `nextcloud-whiteboard-secret`: JWT shared between Nextcloud and the
#   whiteboard backend (only read when `whiteboard` is in `plugins`).
#
# Add both entries to `usr/secrets/` before rebuilding, otherwise sops-nix
# activation will fail.
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

  # The whiteboard backend is useless without the app that talks to it, and
  # it used to run unconditionally even though `whiteboard` is not a default
  # plugin.
  hasWhiteboard = lib.elem "whiteboard" cfg.plugins;

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
    darkone.service.nextcloud.enableSsoRedirect = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Send users straight to Kanidm instead of showing the Nextcloud login
        form (`user_oidc` `allow_multiple_user_backends`). Saves one click on
        every login, including the desktop client's Login Flow v2.

        :::caution[Local login form]
        This hides the password form, admin account included. Reach it with
        `/login?direct=1`.
        :::

        No effect when Kanidm is absent from the network.
      '';
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

      # Whiteboard backend. The JWT is shared between the daemon and the
      # `whiteboard` app: the sops template feeds the daemon's EnvironmentFile,
      # and `nextcloud-whiteboard-setup` below mirrors the same value into the
      # app config. Left to systemd's default (root-owned) ownership on purpose:
      # `EnvironmentFile` is read by PID 1 before the unit drops to its
      # DynamicUser.
      services.nextcloud-whiteboard-server = lib.mkIf hasWhiteboard {
        enable = true;
        settings.NEXTCLOUD_URL = params.href;
        secrets = [ config.sops.templates."nextcloud-whiteboard-env".path ];
      };

      # Read by the `occ` provisioning unit, which runs as the nextcloud user.
      sops.secrets."nextcloud-whiteboard-secret" = lib.mkIf hasWhiteboard {
        mode = "0400";
        owner = "nextcloud";
      };

      sops.templates."nextcloud-whiteboard-env" = lib.mkIf hasWhiteboard {
        content = ''
          JWT_SECRET_KEY=${config.sops.placeholder."nextcloud-whiteboard-secret"}
        '';
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = dnfLib.mkInternalFirewall host zone [ port ];

      #------------------------------------------------------------------------
      # Nextcloud Service
      #------------------------------------------------------------------------

      services.nextcloud = {
        enable = true;

        # Pinned on purpose: nixpkgs would otherwise follow `stateVersion`, and
        # Nextcloud refuses to skip a major (33 -> 35 is impossible, 33 -> 34
        # then 34 -> 35 is the only path). Bump one major at a time, and only
        # once the running instance reports the previous one (`occ status`).
        package = pkgs.nextcloud34;
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
        # `notify_push` is deliberately absent: its own module already adds
        # the app, and defining it twice breaks the merge.
        extraApps =
          let
            inherit (config.services.nextcloud.package.packages) apps;
            enabled = lib.unique (lib.intersectLists cfg.plugins appstoreApps ++ [ "user_oidc" ]);
          in
          lib.genAttrs enabled (name: apps.${name});

        # Apps config
        autoUpdateApps.enable = true;

        # Client push: the desktop client gets change notifications over a
        # websocket instead of polling every 30s (much less PHP churn too).
        # The upstream module grafts a `location ^~ /push/` onto the internal
        # nginx vhost; Caddy already proxies the whole vhost and relays the
        # websocket upgrade, so no extra proxy config is needed.
        notify_push = {
          enable = true;

          # Explicit, because `bendDomainToLocalhost` is off: Caddy runs on the
          # zone gateway, not necessarily on this host, so mapping the domain
          # to 127.0.0.1 would point at nothing.
          nextcloudUrl = params.href;
          bendDomainToLocalhost = false;
          logLevel = "warn";
        };

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

          # 100.64.0.0/10 is the tailnet (CGNAT) range the comment above refers
          # to. It used to read 10.64.0.0/10, which is a subset of the
          # 10.0.0.0/8 entry below — dead weight, and the tailnet was missing.
          trusted_proxies = [
            "100.64.0.0/10"
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

          # `submissions` (465) is implicit TLS -> "ssl"; `submission` (587)
          # upgrades in-band -> "tls".
          mail_smtpsecure = lib.optionalString network.smtp.tls (
            if (network.smtp.protocol or "submissions") == "submissions" then "ssl" else "tls"
          );
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
      # Whiteboard app provisioning
      #------------------------------------------------------------------------

      # `config:app:set` is an upsert, so this is idempotent. Both values were
      # left as TODO comments until now, which meant the app could never reach
      # its backend.
      #
      # The JWT transits through argv for the duration of the call. Acceptable:
      # the unit runs as `nextcloud`, and anything able to read its
      # /proc/<pid>/cmdline already reads the same value straight out of
      # Nextcloud's own config.
      systemd.services.nextcloud-whiteboard-setup = lib.mkIf hasWhiteboard {
        after = [ "nextcloud-setup.service" ];
        requires = [ "nextcloud-setup.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "nextcloud";
        };
        script = ''
          ${lib.getExe config.services.nextcloud.occ} config:app:set \
            whiteboard collabBackendUrl --value="${params.href}"
          ${lib.getExe config.services.nextcloud.occ} config:app:set \
            whiteboard jwt_secret_key \
            --value="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets."nextcloud-whiteboard-secret".path})"
        '';
      };

      #------------------------------------------------------------------------
      # Client push readiness
      #------------------------------------------------------------------------

      # The upstream setup unit self-tests against the PUBLIC url, so it needs
      # Caddy on the zone gateway to be up and the FQDN to resolve. Its own
      # retry window (5 tries over 30s) covers a local race, not a gateway
      # still booting, so widen it — same rationale as `nextcloud-oidc-setup`
      # below. Overrides rather than additions: upstream already sets these.
      systemd.services.nextcloud-notify_push_setup = {
        serviceConfig.RestartSec = lib.mkForce "60s";
        unitConfig = {
          StartLimitIntervalSec = lib.mkForce 900;
          StartLimitBurst = lib.mkForce 10;
        };
      };

      #------------------------------------------------------------------------
      # OIDC provider (Kanidm, via the first-party user_oidc app)
      #------------------------------------------------------------------------

      # `user_oidc:provider <id>` is an upsert, so this is idempotent: it
      # creates the "IDM" provider on first boot and updates it afterwards.
      # Runs as the nextcloud user (occ wrapper expects it); the client secret
      # is read from the sops alias file, never passed on the command line.
      systemd.services.nextcloud-oidc-setup = lib.mkIf hasIdm {
        after = [
          "nextcloud-setup.service"
          "network-online.target"
          "nss-lookup.target"
        ];
        requires = [ "nextcloud-setup.service" ];
        wants = [
          "network-online.target"
          "nss-lookup.target"
        ];
        wantedBy = [ "multi-user.target" ];

        # The discovery URI is fetched at provisioning time, so this unit needs
        # the IdM reachable — and the IdM usually lives on another host,
        # possibly behind the mesh VPN, possibly still booting. Nothing local
        # can express "kanidm is serving", so retry on a slow window instead of
        # leaving a failed unit behind after every reboot.
        startLimitIntervalSec = 900;
        startLimitBurst = 10;
        serviceConfig = {
          Type = "oneshot";
          User = "nextcloud";
          Restart = "on-failure";
          RestartSec = "60s";
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

          # Skip the Nextcloud login form and go straight to Kanidm. Also
          # spares the desktop client's Login Flow v2 one click. `?direct=1`
          # brings the password form back for the admin account.
          ${lib.getExe config.services.nextcloud.occ} config:app:set \
            --type=string --value=${if cfg.enableSsoRedirect then "0" else "1"} \
            user_oidc allow_multiple_user_backends
        '';
      };
    })
  ];
}
