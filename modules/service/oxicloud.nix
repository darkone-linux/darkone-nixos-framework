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
# :::tip[Storage]
# File storage, WebDAV, CalDAV and CardDAV are served on the same HTTP port,
# behind the Caddy reverse proxy. The PostgreSQL database is created locally.
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
      # Database backup
      #------------------------------------------------------------------------

      services.postgresqlBackup.enable = true;

      #------------------------------------------------------------------------
      # OIDC client secret (only when idm is present on the network)
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
          };
        };

        # Client secret injected via env (takes precedence over the option).
        environmentFiles = lib.mkIf hasIdm [ config.sops.templates."oxicloud-oidc-env".path ];
      };
    })
  ];
}
