# A full-configured local Garage S3 service.
#
# Provides an internal S3-compatible object storage backend accessible
# only on 127.0.0.1:3900.
#
# :::note[Manual buckets creation]
# Buckets are NOT created automatically by this module.
# Each consumer service provisions its own bucket and access key via a
# dedicated systemd oneshot unit ordered After= `garage-init.service`.
# Per-consumer credentials are stored in sops as `garage-<consumer>-key-id`
# and `garage-<consumer>-key-secret`, imported into Garage on first boot.
# :::
#
# :::tip[Multi-node cluster migration]
# Single-node, replication_factor = 1. To grow into a multi-node cluster,
# bump `replication_factor`, expose `rpc_public_addr` on the mesh, and
# extend `garage-init` to drive a multi-node layout.
# :::
#
# :::caution[Cluster layout initialization]
# If it fails, wait until the garage service is fully operational, then
# restart it.
# :::

{
  lib,
  pkgs,
  dnfLib,
  config,
  ...
}:
let
  cfg = config.darkone.service.garage;
  srvPort = 3900;
  rpcPort = 3901;
  srvInternalIp = "127.0.0.1";
  s3Region = "garage";
  defaultParams = {
    title = "Garage S3";
    icon = "garage";
    ip = srvInternalIp;
  };
in
{
  options = {
    darkone.service.garage = {
      enable = lib.mkEnableOption "Enable local Garage S3 service";

      # Exposed read-only so consumer modules can stay in sync without
      # hard-coding the values themselves.
      srvPort = lib.mkOption {
        type = lib.types.port;
        default = srvPort;
        readOnly = true;
        description = "S3 API port exposed on the internal IP";
      };
      s3Region = lib.mkOption {
        type = lib.types.str;
        default = s3Region;
        readOnly = true;
        description = "S3 region name (must match consumer config)";
      };

      capacity = lib.mkOption {
        type = lib.types.str;
        default = "1TB";
        example = "500GB";
        description = ''
          Node storage capacity hint passed to `garage layout assign`.
          Used only at first boot for layout initialization; does not act
          as a hard quota on the underlying filesystem.
          Supported suffixes: B, KB, MB, GB, TB, PB.
        '';
      };
    };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.garage = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/garage" ];
        proxy.servicePort = srvPort;
        proxy.isInternal = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "garage";

      #------------------------------------------------------------------------
      # Secrets
      #------------------------------------------------------------------------

      # RPC secret (32-byte hex) shared between the daemon and the CLI.
      # Injected as GARAGE_RPC_SECRET via EnvironmentFile, which systemd
      # reads before dropping privileges to the DynamicUser.
      sops = {
        secrets.garage-rpc-secret = { };
        templates.garage-env = {
          content = ''
            GARAGE_RPC_SECRET=${config.sops.placeholder.garage-rpc-secret}
          '';
          mode = "0400";
          restartUnits = [ "garage.service" ];
        };
      };

      #------------------------------------------------------------------------
      # Garage Service
      #------------------------------------------------------------------------

      services.garage = {
        enable = true;
        package = pkgs.garage;
        environmentFile = config.sops.templates.garage-env.path;
        logLevel = "info";

        # https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/
        settings = {

          # Single-node: one replica is the whole cluster.
          replication_factor = 1;
          db_engine = "sqlite";

          # RPC bound on all interfaces (loopback is enough today,
          # extending to multi-node only requires opening rpc_public_addr).
          rpc_bind_addr = "[::]:${toString rpcPort}";
          rpc_public_addr = "${srvInternalIp}:${toString rpcPort}";

          s3_api = {
            s3_region = s3Region;
            api_bind_addr = "${srvInternalIp}:${toString srvPort}";
          };
        };
      };

      #------------------------------------------------------------------------
      # Cluster layout initialization (one-shot, idempotent)
      #------------------------------------------------------------------------

      # Garage refuses any bucket operation until a cluster layout exists
      # AND the resulting ring has taken effect. Consumer modules depend
      # on this unit (After=/Requires=) so they never race with either.
      systemd.services.garage-init = {
        description = "Initialize Garage cluster layout (single-node)";
        after = [ "garage.service" ];
        requires = [ "garage.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          EnvironmentFile = config.sops.templates.garage-env.path;

          # First boot can be slow on small hosts (sqlite init + RPC
          # warmup + ring activation can easily exceed the default 90s).
          TimeoutStartSec = "10min";
        };
        script = ''
          set -eu

          # Wait until the daemon has registered its own node ID.
          # `garage status` returns 0 as soon as the RPC port is open,
          # which can happen *before* the HEALTHY NODES table is filled
          # in — extracting an empty node_id would then crash the assign.
          node_id=""
          for _ in $(${pkgs.coreutils}/bin/seq 1 120); do
            node_id=$(${pkgs.garage}/bin/garage status 2>/dev/null \
              | ${pkgs.gawk}/bin/awk 'tolower($1) ~ /^[0-9a-f]+$/ { print $1; exit }')
            if [ -n "$node_id" ]; then
              break
            fi
            ${pkgs.coreutils}/bin/sleep 1
          done

          if [ -z "$node_id" ]; then
            echo "garage-init: daemon never reported its node id" >&2
            ${pkgs.garage}/bin/garage status || true
            exit 1
          fi

          # Skip the assignment if a layout is already applied.
          # `garage layout show` prints "Current cluster layout version: N";
          # N=0 means no layout has ever been committed.
          layout=$(${pkgs.garage}/bin/garage layout show 2>&1 || true)
          if echo "$layout" | ${pkgs.gnugrep}/bin/grep -qE 'cluster layout version:[[:space:]]*0\b'; then
            echo "garage-init: assigning layout to node $node_id" >&2
            ${pkgs.garage}/bin/garage layout assign "$node_id" \
              --zone dc1 \
              --capacity ${cfg.capacity} \
              --tag local
            ${pkgs.garage}/bin/garage layout apply --version 1
          fi

          # Wait for the ring to be operational. Until then the daemon
          # logs "Ring not yet ready, read/writes will be lost!" and any
          # bucket/key operation fails — including the ones run by
          # consumer init units that depend on us. `bucket list` is the
          # cheapest call that exercises the ring end-to-end.
          for _ in $(${pkgs.coreutils}/bin/seq 1 120); do
            if ${pkgs.garage}/bin/garage bucket list >/dev/null 2>&1; then
              exit 0
            fi
            ${pkgs.coreutils}/bin/sleep 1
          done

          echo "garage-init: layout applied but ring never became ready" >&2
          ${pkgs.garage}/bin/garage status || true
          ${pkgs.garage}/bin/garage layout show || true
          exit 1
        '';
      };
    })
  ];
}
