# OxiCloud — Fast Sovereign Cloud (file storage, WebDAV, CalDAV & CardDAV).
#
# :::note[Service currently being validated]
# DNF wrapper around the nixpkgs module (from [PR #516113](https://github.com/NixOS/nixpkgs/pull/516113)).
# The `oxicloud` package already ships in nixpkgs; only the module is sourced
# from the fork (cf. `flake.nix` input `nixpkgs-oxicloud`).
# :::
#
# :::tip[SSO]
# When an `idm` (Kanidm) service exists on the network (zone or global), OIDC is
# wired automatically: an OAuth2 client is registered and OxiCloud is pointed at
# the Kanidm endpoints. Without `idm`, the upstream behaviour is left untouched
# (local password login only).
# :::
#
# :::caution[Accounts with SSO]
# - Self-registration is closed: accounts are created at the first SSO login.
# - Members of the Kanidm `admins` group become OxiCloud administrators at that
#   first login only; later role changes are made in the OxiCloud admin UI.
# :::
#
# :::tip[Storage and clients]
# File storage, WebDAV (`/webdav/`), CalDAV (`/caldav`) and CardDAV (`/carddav`)
# are served on the same HTTP port, behind the Caddy reverse proxy. The
# Nextcloud compatibility layer is on: Nextcloud desktop and mobile clients, and
# the GNOME Online Accounts Nextcloud provider, connect to the service URL. The
# PostgreSQL database is created locally.
# :::
#
# :::tip[Mail]
# When `network.smtp` is set, OxiCloud sends share notifications and email
# invitations (magic links) through that relay. Without it, email features are
# disabled.
# :::

{
  lib,
  dnfLib,
  config,
  network,
  host,
  hosts,
  zone,
  ...
}:
let
  cfg = config.darkone.service.oxicloud;
  oxCfg = config.services.oxicloud;
  srvPort = oxCfg.settings.port;
  params = dnfLib.extractServiceParams host network "oxicloud" defaultParams;

  defaultParams = {
    title = "OxiCloud";
    description = "Fast Sovereign Cloud";
    icon = "oxicloud";
  };

  # OIDC context: resolved only when an `idm` service exists on the network.
  # `idmUrl == null` short-circuits all SSO wiring (see below), leaving the
  # upstream password-login behaviour intact.
  inherit
    (dnfLib.mkOidcContext {
      name = "oxicloud";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;
  hasIdm = idmUrl != null;

  # Callback path registered on the Kanidm side; must match `redirectUri`.
  oidcCallbackPath = "/api/auth/oidc/callback";

  # `network.smtp` is optional: without a relay, no mail and no smtp secret.
  hasSmtp = network ? smtp;
  inherit (network) smtp;

  # Same set as Caddy's `trusted_proxies static private_ranges 100.64.0.0/10`:
  # Caddy reaches us from the zone gateway, the HCS (tailnet) or loopback.
  # Unset, login rate-limit and lockout key on Caddy's IP, shared by all users.
  trustedProxyCidrs = [
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "127.0.0.0/8"
    "100.64.0.0/10"
    "fd00::/8"
    "::1/128"
  ];

  # Two-letter locales shipped in upstream `static/locales/`: an unknown
  # `OXICLOUD_DEFAULT_LOCALE` aborts the startup, so fall back on upstream (`en`).
  shippedLocales = [
    "ar"
    "de"
    "en"
    "es"
    "fa"
    "fr"
    "hi"
    "it"
    "ja"
    "ko"
    "nl"
    "pl"
    "pt"
    "ru"
    "zh"
  ];
  lang = builtins.substring 0 2 config.darkone.system.i18n.locale;
in
{
  options = {
    darkone.service.oxicloud.enable = lib.mkEnableOption "Enable local OxiCloud service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.oxicloud = {
        inherit defaultParams;
        persist = {
          dirs = [ oxCfg.dataDir ];
          dbDirs = [ config.services.postgresql.dataDir ];
        };
        proxy.servicePort = srvPort;
      };

      # Kanidm OAuth2 client template (provisioned only when idm is enabled).
      darkone.service.idm.oauth2.oxicloud = {
        displayName = "OxiCloud";
        imageFile = ./../../assets/app-icons/oxicloud.svg;
        redirectPaths = [ oidcCallbackPath ];
        landingPath = "/";
        allowInsecureClientDisablePkce = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "oxicloud";

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      # Web service behind the Caddy reverse proxy: internal interfaces only.
      networking.firewall = dnfLib.mkInternalFirewall host zone [ srvPort ];

      #------------------------------------------------------------------------
      # Database
      #------------------------------------------------------------------------

      services.postgresqlBackup.enable = true;

      # `ensureUsers` runs in `postgresql-setup.service`: upstream orders on
      # `postgresql.service` only, so a first boot races the role creation.
      systemd.services.oxicloud = {
        after = [ "postgresql.target" ];
        requires = [ "postgresql.target" ];
      };

      #------------------------------------------------------------------------
      # Secrets (OIDC client secret, SMTP password)
      #------------------------------------------------------------------------

      # Re-encrypted alias of the kanidm-owned OAuth2 secret, readable by the
      # oxicloud user (sops `key` field unmaps the master secret name). Rendered
      # into an EnvironmentFile because upstream reads the secret from the env
      # (OXICLOUD_OIDC_CLIENT_SECRET), never from a Nix-store option.
      sops.secrets."${secret}-service" = lib.mkIf hasIdm {
        mode = "0400";
        owner = "oxicloud";
        key = secret;
      };

      sops.templates."oxicloud-oidc-env" = lib.mkIf hasIdm {
        content = "OXICLOUD_OIDC_CLIENT_SECRET=${config.sops.placeholder."${secret}-service"}";
        mode = "0400";
        owner = "oxicloud";
        restartUnits = [ "oxicloud.service" ];
      };

      sops.secrets."smtp/password" = lib.mkIf hasSmtp { };

      sops.templates."oxicloud-smtp-env" = lib.mkIf hasSmtp {
        content = "OXICLOUD_SMTP_PASS=${config.sops.placeholder."smtp/password"}";
        mode = "0400";
        owner = "oxicloud";
        restartUnits = [ "oxicloud.service" ];
      };

      #------------------------------------------------------------------------
      # OxiCloud Service
      #------------------------------------------------------------------------

      services.oxicloud = {
        enable = true;

        # Local PostgreSQL database + role (peer auth via the default
        # `postgres:///oxicloud?host=/run/postgresql` connection string).
        createLocalDatabase = true;

        # Reverse proxy reaches the service on the host's resolved IP.
        openFirewall = false;

        settings = {

          # Bind where Caddy connects (cf. `params.ip`); public URL is the FQDN.
          host = params.ip;
          baseUrl = params.href;

          oidc = lib.mkIf hasIdm {
            enable = true;
            issuerUrl = oidc.issuerUrl;
            inherit clientId;
            redirectUri = "${params.href}${oidcCallbackPath}";
            frontendUrl = params.href;

            # `groups` is not requested upstream. Kanidm emits group SPNs
            # (`admins@<domain>`); the short name is a fallback.
            scopes = [
              "openid"
              "profile"
              "email"
              "groups"
            ];
            adminGroups = [
              "admins"
              "admins@${network.domain}"
            ];
          };

          extraEnvironment = lib.mkMerge [
            {
              OXICLOUD_TRUST_PROXY_CIDR = lib.concatStringsSep "," trustedProxyCidrs;

              # Nextcloud API layer (`/remote.php/`, `/ocs/`, Login Flow v2).
              OXICLOUD_NEXTCLOUD_ENABLED = true;

              # Server-rendered pages and emails; `null` keeps the upstream default.
              OXICLOUD_DEFAULT_LOCALE = if lib.elem lang shippedLocales then lang else null;
            }

            # Accounts come from Kanidm (JIT provisioning at first SSO login).
            (lib.mkIf hasIdm { OXICLOUD_DISABLE_REGISTRATION = true; })

            # Password comes from the sops environment file.
            (lib.mkIf hasSmtp {
              OXICLOUD_SMTP_HOST = smtp.server;
              OXICLOUD_SMTP_PORT = smtp.port;
              OXICLOUD_SMTP_USER = smtp.username;
              OXICLOUD_SMTP_FROM = "OxiCloud ${network.domain} <noreply@${network.domain}>";

              # `submissions` (465) is implicit TLS; `submission` (587)
              # upgrades in-band.
              OXICLOUD_SMTP_TLS =
                if !smtp.tls then
                  "none"
                else if (smtp.protocol or "submissions") == "submissions" then
                  "tls"
                else
                  "starttls";
            })
          ];
        };

        # Secrets injected via env (take precedence over the options).
        environmentFiles =
          lib.optional hasIdm config.sops.templates."oxicloud-oidc-env".path
          ++ lib.optional hasSmtp config.sops.templates."oxicloud-smtp-env".path;
      };
    })
  ];
}
