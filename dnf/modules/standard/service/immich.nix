# Immich (photo management) full-configured service.

{
  lib,
  dnfLib,
  config,
  pkgs,
  host,
  ...
}:
let
  cfg = config.darkone.service.immich;
  params = dnfLib.extractServiceParams host "immich" { description = "Smart media manager"; };
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
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.immich = {
        inherit params;
        persist = {
          dirs = [
            "/var/lib/immich/profile"
            "/var/lib/immich/backups"
          ];
          dbDirs = [ "/var/lib/postgresql" ];
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
        proxy.servicePort = config.services.immich.port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.immich.enable = true;
      };

      # Redis for caching (optional but recommended)
      services.redis.servers.immich = lib.mkIf cfg.enableRedis {
        enable = true;
        port = 6379;
        bind = "127.0.0.1";
        requirePass = null; # Local access only
        settings = {

          # Optimizations for immich caching
          maxmemory = "256mb";
          maxmemory-policy = "allkeys-lru";

          # Persistence settings
          save = "900 1 300 10 60 10000";

          # Performance settings
          tcp-keepalive = 60;
          timeout = 300;
        };
      };

      # Main immich service configuration
      services.immich = {
        enable = true;
        port = 2283;
        host = params.ip;
        openFirewall = false;

        # Redis configuration
        redis = lib.mkIf cfg.enableRedis {
          host = "127.0.0.1";
          inherit (config.services.redis.servers.immich) port;
        };

        # Database fix
        database = {
          enableVectors = false;
          enableVectorChord = true;
        };

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

      # Machine learning fix
      # https://discourse.nixos.org/t/immich-machine-learning-not-working/69208
      users.users.immich = {
        home = "/var/lib/immich";
        createHome = true;
      };

      # System packages needed for immich functionality
      environment.systemPackages = with pkgs; [
        imagemagick
        libraw
        ffmpeg-full
        redis
      ];

      # Permet l'accès à /home (si les images sont dans des homes directories)
      systemd.services = {
        immich-server.serviceConfig = {
          ProtectHome = lib.mkForce false;
        };
        immich-microservices.serviceConfig = {
          ProtectHome = lib.mkForce false;
        };
      };
    })
  ];
}
