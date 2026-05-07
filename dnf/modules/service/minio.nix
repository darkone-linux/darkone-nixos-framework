# A full-configured local MinIO S3 service. (wip)
#
# Provides an internal S3-compatible object storage backend accessible
# only on 127.0.0.1:9000. The console web UI runs on 127.0.0.1:9001
# for administration and debugging.
#
# :::note
# Buckets are NOT created automatically by this module.
# Each consumer service is responsible for creating its own buckets
# via a systemd postStart hook using the `mc` (MinIO Client) tool.
# Credentials are managed through sops.
# :::

{ lib, config, ... }:
let
  cfg = config.darkone.service.minio;
  srvPort = 9000;
  consolePort = 9001;
  srvInternalIp = "127.0.0.1";
  defaultParams = {
    title = "MinIO S3";
    icon = "minio";
    ip = srvInternalIp;
  };
in
{
  options = {
    darkone.service.minio.enable = lib.mkEnableOption "Enable local MinIO S3 service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.minio = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/minio" ];
        proxy.servicePort = srvPort;
        proxy.isInternal = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.minio.enable = true;
      };

      #------------------------------------------------------------------------
      # Secrets
      #------------------------------------------------------------------------

      # MinIO root credentials
      sops = {
        secrets.minio-root-user = { };
        secrets.minio-root-password = { };
        templates.minio-env = {
          content = ''
            MINIO_ROOT_USER=${config.sops.placeholder.minio-root-user}
            MINIO_ROOT_PASSWORD=${config.sops.placeholder.minio-root-password}
          '';
          mode = "0400";
          owner = "minio";
          restartUnits = [ "minio.service" ];
        };
      };

      #------------------------------------------------------------------------
      # MinIO Service
      #------------------------------------------------------------------------

      services.minio = {
        enable = true;
        listenAddress = "${srvInternalIp}:${toString srvPort}";
        consoleAddress = "${srvInternalIp}:${toString consolePort}";
        region = "us-east-1";
        browser = true;
        rootCredentialsFile = config.sops.templates.minio-env.path;
        dataDir = [ "/var/lib/minio/data" ];
      };
    })
  ];
}
