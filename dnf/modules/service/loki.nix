# Loki + Alloy, http stats with grafana.
#
# :::note
# Centralized collection of Caddy access logs, consumed by Grafana via
# a provisioned Loki datasource and a dedicated dashboard.
#
# Dual pattern aligned with monitoring.nix:
# - `enable`   : deploys the Loki server + Grafana datasource on the
#   same host that runs the `monitoring` service (Grafana).
# - `isClient` : deploys Promtail on each host running Caddy. Caddy
#   logs are expected in JSON at `/var/log/caddy/access-*.log`
#   (see `dnf/modules/system/services.nix`).
#
# By default, `enable` follows `darkone.service.monitoring.enable` and
# `isClient` follows `services.caddy.enable`: setup is fully automatic
# once monitoring and Caddy are active.
# :::
#
# :::tip Debugging & manual cleanup
# Most common symptoms after a Loki (de)activation or Caddy log format change:
#
# **1. "NO DATA" on the Caddy dashboard despite incoming requests.**
#    Check the ingestion chain end-to-end:
#    ```sh
#    # On the Caddy host: is Alloy running? reading files?
#    sudo systemctl status alloy --no-pager
#    sudo journalctl -u alloy -n 100 --no-pager | grep -iE 'error|permission'
#    ls -la /var/log/caddy/access-*.log   # must be caddy:caddy
#
#    # On the monitoring host: is Loki receiving anything?
#    # (replace <IP> with the monitoring host's internal IP, Loki does NOT
#    # bind on 127.0.0.1 — see http_listen_address = bindAddr)
#    curl -s http://<IP>:3100/loki/api/v1/labels | jq
#    curl -sG http://<IP>:3100/loki/api/v1/query \
#         --data-urlencode 'query={job="caddy"}' | jq '.data.result | length'
#    ```
#
# **2. `alloy.service: mkdir data-alloy/remotecfg: permission denied`.**
#    Orphaned ownership of `/var/lib/alloy` inherited from a former DynamicUser.
#    The service `ExecStartPre` normally fixes it, but if stuck (e.g. unit in
#    `start-limit-hit`):
#    ```sh
#    sudo systemctl stop alloy
#    sudo chown -R caddy:caddy /var/lib/alloy
#    sudo systemctl reset-failed alloy
#    sudo systemctl start alloy
#    ```
#
# **3. Grafana refuses to start: `Datasource provisioning error: data
#    source not found`.** UID conflict in SQLite DB after provision change
#    (typically switching from auto-generated UID to `uid = "loki"`).
#    The `deleteDatasources` option handles this in theory; otherwise manual
#    purge:
#    ```sh
#    sudo systemctl stop grafana
#    sudo sqlite3 /var/lib/grafana/grafana.db \
#         "DELETE FROM data_source WHERE name='Loki';"
#    sudo systemctl reset-failed grafana
#    sudo systemctl start grafana
#    ```
#
# **4. Stale Caddy log files** (old naming with `:` or schema, e.g.
#    `access-http:__nextcloud.log`). Harmless but pollute Alloy tail output.
#    Clean up after a migration:
#    ```sh
#    sudo rm /var/log/caddy/access-{http,https}:__*.log
#    sudo rm /var/log/caddy/access-:*.log     # variants `:80`, `:443`
#    sudo systemctl reload caddy              # optional
#    ```
# :::

{
  lib,
  pkgs,
  config,
  dnfLib,
  hosts,
  host,
  network,
  zone,
  ...
}:
let
  cfg = config.darkone.service.loki;

  port = {
    loki = 3100;
  };

  # Host running the monitoring service (Grafana). Logs are pushed there.
  monitoringSvc = lib.findFirst (s: s.name == "monitoring") null network.services;
  monitoringHost =
    if monitoringSvc != null then dnfLib.findHost monitoringSvc.host monitoringSvc.zone hosts else { };
  lokiAddr = dnfLib.preferredIp monitoringHost;
  lokiUrl = "http://${lokiAddr}:${toString port.loki}";

  # Local bind address (VPN if available, otherwise LAN).
  bindAddr = dnfLib.preferredIp host;
in
{
  options = {
    darkone.service.loki.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.darkone.service.monitoring.enable;
      description = "Deploys the Loki server + Grafana datasource (colocated with Grafana).";
    };
    darkone.service.loki.isClient = lib.mkOption {
      type = lib.types.bool;
      default = config.services.caddy.enable;
      description = "Deploys Promtail to collect local Caddy access logs.";
    };
    darkone.service.loki.retentionTime = lib.mkOption {
      type = lib.types.str;
      default = "720h";
      description = "Log retention duration in Loki (30 days by default).";
    };
  };

  config = lib.mkMerge [

    #--------------------------------------------------------------------------
    # DNF Service registration (always)
    #--------------------------------------------------------------------------

    {
      darkone.system.services.service.loki = {
        persist.varDirs =
          lib.optional cfg.enable "/var/lib/loki" ++ lib.optional cfg.isClient "/var/lib/alloy";
        proxy.enable = false; # internal access only, no Caddy vhost
        proxy.servicePort = port.loki;
        proxy.isInternal = true;
      };
    }

    #--------------------------------------------------------------------------
    # Loki server (colocated with Grafana)
    #--------------------------------------------------------------------------

    (lib.mkIf cfg.enable {

      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;

          server = {
            http_listen_address = bindAddr;
            http_listen_port = port.loki;
            grpc_listen_address = bindAddr;
            grpc_listen_port = 9096;
          };

          common = {
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            ring = {
              kvstore.store = "inmemory";
              instance_addr = bindAddr;
            };
          };

          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];

          storage_config = {
            tsdb_shipper = {
              active_index_directory = "/var/lib/loki/tsdb-index";
              cache_location = "/var/lib/loki/tsdb-cache";
            };
            filesystem.directory = "/var/lib/loki/chunks";
          };

          limits_config = {
            retention_period = cfg.retentionTime;
            reject_old_samples = true;
            reject_old_samples_max_age = "168h";
            allow_structured_metadata = true;
          };

          compactor = {
            working_directory = "/var/lib/loki/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };

          analytics.reporting_enabled = false;
        };
      };

      services.grafana.provision.datasources.settings = {

        # `deleteDatasources` purges any pre-existing "Loki" entry from the
        # SQLite DB before re-insertion: without this, switching from an
        # auto-generated UID to a fixed one ("loki") causes "data source not found"
        # at Grafana boot (Grafana 11+ tries an update by UID and fails).
        # Idempotent operation: delete-then-insert on every restart.
        deleteDatasources = [
          {
            name = "Loki";
            orgId = 1;
          }
        ];

        # Loki datasource + Caddy dashboard (mkMerge with monitoring.nix).
        # `uid = "loki"` is explicit: the caddy-access dashboard references
        # the datasource by this UID (see `"datasource": { "uid": "loki" }`
        # in the JSON). Without this fixed UID, Grafana generates a random one
        # and all panels show "datasource not found".
        datasources = [
          {
            name = "Loki";
            type = "loki";
            uid = "loki";

            # Loki binds on `lokiAddr` (see http_listen_address above), not
            # on 127.0.0.1. Grafana runs on the same host but must target the
            # same IP used for the bind (zone internal IP).
            url = "http://${lokiAddr}:${toString port.loki}";
            isDefault = false;
            editable = false;
          }
        ];
      };

      environment.etc."grafana-dashboards/caddy-access.json".source = ./loki/caddy-access.json;

      # Home dashboard + kiosk redirect override. The user
      # lands on monitoring.zone.tld/ and is redirected to this home dashboard
      # which lists available dashboards. mkDefault lets the end user
      # override the target from usr/ if they prefer another menu.
      environment.etc."grafana-dashboards/monitoring-home.json".source = ./loki/monitoring-home.json;
      darkone.service.monitoring.kioskTarget = lib.mkDefault "d/dnf-monitoring-home/home?kiosk";

      # Loki listens on the internal interface (VPN or LAN depending on
      # topology). On a host without an internal interface, the port opens
      # globally, which is safe since Loki only runs on the monitoring host
      # (typically the HCS, already filtered upstream).
      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = [ port.loki ];
      };
    })

    #--------------------------------------------------------------------------
    # Grafana Alloy client (on each host running Caddy)
    #
    # Promtail has reached end of life, its official successor
    # `grafana-alloy` plays the same role: tail Caddy files + JSON parsing
    # + push to Loki. River configuration is placed at
    # `/etc/alloy/config.alloy` (default path for `services.alloy`).
    #--------------------------------------------------------------------------

    (lib.mkIf cfg.isClient {

      services.alloy.enable = true;

      # Disable usage reporting to stats.grafana.org: otherwise Alloy
      # tries every ~4h to POST an external telemetry payload.
      services.alloy.extraFlags = [ "--disable-reporting" ];

      environment.etc."alloy/config.alloy".text = ''
        local.file_match "caddy" {
          path_targets = [
            {
              __path__ = "/var/log/caddy/access-*.log",
              job      = "caddy",
              host     = "${host.hostname}",
              zone     = "${zone.name}",
            },
          ]
        }

        loki.source.file "caddy" {
          targets    = local.file_match.caddy.targets
          forward_to = [loki.process.caddy.receiver]
        }

        loki.process "caddy" {
          forward_to = [loki.write.default.receiver]

          stage.json {
            expressions = {
              ts       = "ts",
              status   = "resp_status_code",
              method   = "request.method",
              vhost    = "request.host",
              duration = "duration",
            }
          }

          stage.labels {
            values = {
              status = "",
              method = "",
              vhost  = "",
            }
          }

          stage.timestamp {
            source = "ts"
            format = "Unix"
          }
        }

        loki.write "default" {
          endpoint {
            url = "${lokiUrl}/loki/api/v1/push"
          }
        }
      '';

      # Run Alloy directly as `caddy:caddy` (instead of the default DynamicUser).
      # Reason: Caddy creates its access logs with mode `0600` (hardcoded in its
      # Go writer, no override from Caddyfile), so even adding Alloy to the
      # `caddy` group via SupplementaryGroups, mode 0600 blocks group read.
      # By becoming the file owner, Alloy can tail them.
      # `mkForce` is needed to override the upstream module defaults.
      systemd.services.alloy.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "caddy";
        Group = lib.mkForce "caddy";
        SupplementaryGroups = lib.mkForce [ "systemd-journal" ];

        # `ExecStartPre` (`+` prefix => executed as root, regardless of `User=`)
        # ensures `/var/lib/alloy` and its contents (notably `data-alloy/`
        # created by Alloy itself) belong to `caddy:caddy` on every start.
        # Without this, on a new host or one migrated from the old DynamicUser,
        # we get `mkdir data-alloy/remotecfg: permission denied` because
        # systemd's StateDirectory does not chown recursively and tmpfiles only
        # runs at boot (not on switch).
        ExecStartPre = [ "+${pkgs.coreutils}/bin/chown -R caddy:caddy /var/lib/alloy" ];
      };
    })
  ];
}
