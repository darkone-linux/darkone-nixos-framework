# Immich (photo management) full-configured service.

{
  lib,
  dnfLib,
  dnfConfig,
  config,
  pkgs,
  network,
  host,
  hosts,
  zone,
  ...
}:
let
  cfg = config.darkone.service.immich;
  srv = config.services.immich;
  defaultParams = {
    description = "Smart media manager";
  };
  params = dnfLib.extractServiceParams host network "immich" defaultParams;

  inherit
    (dnfLib.mkOidcContext {
      name = "immich";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;

  # No Kanidm on this network ⇒ skip all SSO wiring.
  hasIdm = idmUrl != null;
in
{
  options = {
    darkone.service.immich.enable = lib.mkEnableOption "Enable local immich service";
    darkone.service.immich.enableMachineLearning = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable machine learning features (face recognition, object detection)";
    };
    darkone.service.immich.enableRedis = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Redis for caching (recommended for performance)";
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.immich = {
        inherit defaultParams;
        persist = {
          dirs = [
            "/var/lib/immich/profile"
            "/var/lib/immich/backups"
          ];
          dbDirs = [ config.services.postgresql.dataDir ];
          mediaDirs = [ "/var/lib/immich/library" ];
          varDirs = [
            "/var/lib/immich/encoded-video"
            "/var/lib/immich/thumbs"
            "/var/lib/immich/upload"
            "/var/lib/immich/.cache"
            "/var/lib/immich/.config"
            "/var/lib/cache/immich"
            (lib.mkIf cfg.enableRedis "/var/lib/redis-immich")
          ];
        };
        proxy.servicePort = srv.port;
        proxy.extraConfig = dnfLib.mkCaddySecurityHeaders { maxUploadSize = "4GB"; };
      };

      # Kanidm OAuth2 client template. Consumer side is wired declaratively
      # below via `services.immich.settings.oauth`.
      darkone.service.idm.oauth2.immich = {
        displayName = "Immich";
        imageFile = ./../../assets/app-icons/immich.svg;
        redirectPaths = [
          "/auth/login"
          "/user-settings"

          # Custom scheme for the mobile app — kept as absolute URL by idm.nix.
          "app.immich:///oauth-callback"
        ];
        landingPath = "/";
        allowInsecureClientDisablePkce = false;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "immich";

      #------------------------------------------------------------------------
      # Secrets
      #------------------------------------------------------------------------

      # Re-encrypted alias of the kanidm-owned OAuth2 secret. The immich module
      # injects it into /run/immich/config.json at runtime (via the settings
      # `_secret` mechanism), so the secret never lands in the Nix store.
      sops.secrets."${secret}-service" = lib.mkIf hasIdm {
        mode = "0400";
        owner = "immich";
        key = secret;
      };

      #------------------------------------------------------------------------
      # Immich dependencies
      #------------------------------------------------------------------------

      # Redis for caching (optional but recommended)
      services.redis.servers.immich = lib.mkIf cfg.enableRedis {
        enable = true;
        port = dnfConfig.network.ports.immichRedis;
        bind = "127.0.0.1";
        requirePass = null; # Local access only
        settings = {

          # Optimizations for immich caching
          maxmemory = "1024mb";
          maxmemory-policy = "allkeys-lru";

          # Persistence settings
          save = "900 1 300 10 60 10000";

          # Performance settings
          tcp-keepalive = 60;
          timeout = 300;
        };
      };

      # Open internal port only if necessary on the right interface
      # https://github.com/NixOS/nixpkgs/blob/a6531044f6d0bef691ea18d4d4ce44d0daa6e816/nixos/modules/services/web-apps/immich.nix#L362C68-L362C71
      networking.firewall = dnfLib.mkInternalFirewall host zone [ srv.port ];

      # Media for external libraries
      darkone.system.srv-dirs.enableMedias = true;

      #------------------------------------------------------------------------
      # Related services
      #------------------------------------------------------------------------

      # PostgreSQL backup (all databases by default)
      services.postgresqlBackup.enable = true;

      #------------------------------------------------------------------------
      # Immich Service
      #------------------------------------------------------------------------

      # Main immich service configuration
      services.immich = {
        enable = true;
        port = dnfConfig.network.ports.immich;
        host = host.ip;
        openFirewall = false;

        # Declarative Kanidm OIDC. Writing `settings` makes the OAuth panel
        # read-only in the Immich UI (config owned by Nix). The client secret
        # is merged in at runtime from a file via the `_secret` mechanism, so
        # it never lands in the Nix store.
        settings.oauth = lib.mkIf hasIdm {
          enabled = true;
          issuerUrl = oidc.issuerUrl;
          clientId = clientId;
          scope = "openid email profile";

          # Kanidm signs with ES256 by default (enableLegacyCrypto = false).
          signingAlgorithm = "ES256";
          buttonText = "Login with IDM";
          autoRegister = true;

          # Mobile app deep-link callback (also declared in the idm template).
          mobileOverrideEnabled = true;
          mobileRedirectUri = "app.immich:///oauth-callback";

          clientSecret._secret = config.sops.secrets."${secret}-service".path;
        };

        # Redis configuration
        redis = lib.mkIf cfg.enableRedis {
          host = "127.0.0.1";
          inherit (config.services.redis.servers.immich) port;
        };

        # Database fix (deprecated)
        #database = {
        #  enableVectors = false;
        #  # enableVectorChord = true; # Deprecated. From now on, vectorchord is always enabled.
        #};

        # Machine learning configuration
        machine-learning = lib.mkIf cfg.enableMachineLearning {
          enable = true;

          # Additional ML settings can be configured here
          environment = {

            # Optimize for CPU if no GPU available
            TRANSFORMERS_CACHE = "/var/lib/immich/cache/transformers";
            TORCH_HOME = "/var/lib/immich/cache/torch";

            # Machine learning fix
            # https://discourse.nixos.org/t/immich-machine-learning-not-working/69208
            HF_XET_CACHE = "/var/cache/immich/huggingface-xet";
          };
        };
      };

      # Machine learning fix + common-files
      # https://discourse.nixos.org/t/immich-machine-learning-not-working/69208
      users.users.immich = {
        home = "/var/lib/immich";
        createHome = true;
        extraGroups = [ "common-files" ];
      };

      # System packages needed for immich functionality
      environment.systemPackages = with pkgs; [
        imagemagick
        libraw
        ffmpeg-full
        redis
      ];

      # Allow access to /home (if images are in home directories)
      # And UMask for write access by common-files group
      systemd.services = {
        immich-server.serviceConfig = {
          ProtectHome = lib.mkForce false;
          UMask = lib.mkForce "0006";
          Group = lib.mkForce "common-files";
          SupplementaryGroups = "immich";
        };
        immich-microservices.serviceConfig = {
          ProtectHome = lib.mkForce false;
          UMask = lib.mkForce "0006";
          Group = lib.mkForce "common-files";
          SupplementaryGroups = "immich";
        };
      };
    })
  ];
}
