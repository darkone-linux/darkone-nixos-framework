# Supervision module with prometheus, grafana and node exporter.
#
# :::tip
# This module is preconfigured with a configuration that allows you
# to monitor the operating system, network activity, resources, and performance.
# :::

{ lib, config, ... }:
let
  cfg = config.darkone.service.monitoring;
  port = {
    grafana = 3222;
    nodeExporter = 9100;
    prometheus = config.services.prometheus.port;
  };
in
{
  options = {
    darkone.service.monitoring.enable = lib.mkEnableOption "Enable monitoring with prometheus, grafana and node exporter";
    darkone.service.monitoring.domainName = lib.mkOption {
      type = lib.types.str;
      default = "monitoring";
      description = "Domain name for monitoring, registered in nginx & hosts";
    };
    darkone.service.monitoring.retentionTime = lib.mkOption {
      type = lib.types.str;
      default = "15d";
      description = "Durée de rétention des métriques Prometheus";
    };
  };

  # Prometheus + Grafana + Node Exporter
  # TODO: password access
  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.monitoring = {
        inherit (cfg) domainName;
        displayName = "Monitoring";
        description = "Visualisation des ressources système et réseau";
        icon = "grafana";
        persist = {
          dbFiles = [ "/var/lib/grafana/grafana.db" ];
          varDirs = [
            "/var/lib/prometheus2"
            "/var/lib/grafana/plugins"
            "/var/lib/grafana/data"
          ];
        };
        nginx.manageVirtualHost = false;
      };
    }

    (lib.mkIf cfg.enable {

      #--------------------------------------------------------------------------
      # Home page + virtualhost
      #--------------------------------------------------------------------------

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.monitoring = {
          enable = true;
        };
      };

      # Virtualhost for monitoring
      services.nginx = {
        enable = lib.mkForce true;
        virtualHosts.${cfg.domainName} = {
          extraConfig = ''
            client_max_body_size 512M;
          '';
          locations."= /" = {
            return = "302 /d/rYdddlPWk/node-exporter-full?kiosk";
          };
          locations."/" = {
            proxyPass = "http://localhost:${toString port.grafana}/";
            proxyWebsockets = true;
            recommendedProxySettings = true;
          };
        };
      };

      #--------------------------------------------------------------------------
      # Prometheus
      #--------------------------------------------------------------------------

      # Prometheus (scraping du node exporter)
      services.prometheus = {
        enable = true;
        inherit (cfg) retentionTime;
        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = [ { targets = [ "localhost:${toString port.nodeExporter}" ]; } ];
            scrape_interval = "15s";
          }
        ];
        globalConfig = {
          scrape_interval = "15s";
          evaluation_interval = "15s";
        };
        exporters.node = {
          enable = true;
          port = port.nodeExporter;
          enabledCollectors = [
            "arp"
            "btrfs"
            "conntrack"
            "filesystem"
            "interrupts"
            "ksmd"
            "loadavg"
            "logind"
            "meminfo"
            "netdev"
            "netstat"
            "pressure"
            "sockstat"
            "stat"
            "systemd"
            "textfile"
            "time"
            "vmstat"
            "wifi"
          ];
          disabledCollectors = [
            "bonding"
            "edac"
            "entropy"
            "hwmon"
            "infiniband"
            "ipvs"
            "mdadm"
            "nfs"
            "nfsd"
            "powersupplyclass"
            "rapl"
            "schedstat"
            "selinux"
            "thermal_zone"
            "timex"
            "xfs"
            "zfs"
          ];
        };
      };

      #--------------------------------------------------------------------------
      # Grafana
      #--------------------------------------------------------------------------

      # Grafana avec datasource + dashboard
      services.grafana = {
        enable = true;

        settings = {
          server = {
            http_addr = "127.0.0.1";
            http_port = port.grafana;
            domain = cfg.domainName;
            root_url = "http://" + cfg.domainName + "/";
            serve_from_sub_path = false;
          };
          #security = {
          #  admin_user = "admin";
          #  admin_password = "admin";
          #};
          database = {
            type = "sqlite3";
            path = "/var/lib/grafana/grafana.db";
          };
          analytics = {
            reporting_enabled = false;
            check_for_updates = false;
            feedback_links_enabled = false;
            check_for_plugin_updates = false;
          };
          plugins = {
            allow_loading_unsigned_plugins = false;
            plugin_catalog_url = null;
          };
          news = {
            news_feed_enabled = false;
          };
          auth.disable_login_form = true;
          "auth.anonymous".enabled = true;
        };

        provision = {
          enable = true;

          datasources.settings.datasources = [
            {
              name = "Prometheus";
              type = "prometheus";
              url = "http://${config.services.prometheus.listenAddress}:${toString config.services.prometheus.port}";
              isDefault = true;
              editable = false;
            }
          ];

          dashboards.settings.providers = [
            {
              name = "Monitoring local";
              disableDeletion = true;
              allowUiUpdates = false;
              options = {
                path = "/etc/grafana-dashboards";
                foldersFromFilesStructure = true;
              };
            }
          ];
        };
      };

      #--------------------------------------------------------------------------
      # Dashboards
      #--------------------------------------------------------------------------

      environment.etc."grafana-dashboards/node-explorer.json".source = ./monitoring/node-explorer.json;

      # Ouverture des ports dans le firewall
      #networking.firewall.allowedTCPPorts = [
      #  port.grafana
      #  port.nodeExporter
      #  port.prometheus
      #];
    })
  ];
}
