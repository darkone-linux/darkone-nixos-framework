# Supervision module with prometheus, grafana and node exporter.
#
# :::tip
# This module is preconfigured with a configuration that allows you
# to monitor the operating system, network activity, resources, and performance.
# For each zone:
#
# - All nodes with tag "monitoring-node" contains prometheus + node exporter.
# - The node with service "monitoring" contains grafana.
# - Only one monitoring host per zone is accepted.
# - A tag "monitoring-node:[zone]" is attached to a monitoring host of the designed zone.
# :::

{
  lib,
  config,
  dnfLib,
  hosts,
  host,
  network,
  zone,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.monitoring;
  port = {
    grafana = 3222;
    nodeExporter = 9100;
    prometheus = config.services.prometheus.port;
  };

  # Nodes supervisés par la zone courante
  nodes = lib.filter (
    h: lib.hasAttr "monitoring-node" h.features && h.features.monitoring-node == zone.name
  ) hosts;

  # Service params
  defaultParams = {
    description = "System and Network Statistics";
    icon = "grafana";
  };
  params = dnfLib.extractServiceParams host network "monitoring" defaultParams;
in
{
  options = {
    darkone.service.monitoring.enable = lib.mkEnableOption "Enable monitoring with prometheus, grafana and node exporter";
    darkone.service.monitoring.isNode = lib.mkOption {
      type = lib.types.bool;
      default = lib.hasAttrByPath [ "features" "monitoring-node" ] host;
      description = "Is a monitoring node";
    };
    darkone.service.monitoring.retentionTime = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      description = "Durée de rétention des métriques Prometheus";
    };
  };

  # Prometheus + Grafana + Node Exporter
  # TODO: password access
  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.monitoring = {
        inherit defaultParams;
        persist = {
          dbFiles = lib.optional cfg.enable "/var/lib/grafana/grafana.db";
          varDirs = [
            "/var/lib/prometheus2"
          ]
          ++ lib.optionals cfg.enable [
            "/var/lib/grafana/plugins"
            "/var/lib/grafana/data"
          ];
        };
        proxy.enable = cfg.enable;
        proxy.servicePort = lib.mkIf cfg.enable port.grafana;
        #proxy.preExtraConfig = "import auth"; # Authelia
        proxy.extraConfig = lib.optionalString cfg.enable "redir / /d/rYdddlPWk/node-exporter-full?kiosk";
      };
    }

    (lib.mkIf (cfg.enable || cfg.isNode) {

      #--------------------------------------------------------------------------
      # Home page + virtualhost
      #--------------------------------------------------------------------------

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.monitoring.enable = true;
      };

      #--------------------------------------------------------------------------
      # Node exporter
      #--------------------------------------------------------------------------

      # https://github.com/prometheus/node_exporter
      services.prometheus.exporters.node = lib.mkIf cfg.isNode {
        enable = true;
        port = port.nodeExporter;
        openFirewall = false;
        listenAddress = host.vpnIp or host.ip;
        enabledCollectors = [
          "ethtool"
          "interrupts"
          "ksmd"
          "logind"
          "netstat"
          "softirqs"
          "systemd"
          "tcpstat"
          "wifi"
        ];
        disabledCollectors = [
          "bonding"
          "edac"
          "entropy"
          "infiniband"
          "ipvs"
          "powersupplyclass"
          "rapl"
          "schedstat"
          "selinux"
          "xfs"
          "zfs"
        ];
      };

      # Open the node explorer port if needed
      networking.firewall = lib.mkIf cfg.isNode (
        lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
          allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ port.nodeExporter ];
        }
      );

      # Additional packages
      environment.systemPackages = lib.optionals cfg.isNode [
        pkgs.ethtool
        pkgs.unixtools.netstat
      ];

      #--------------------------------------------------------------------------
      # Prometheus
      #--------------------------------------------------------------------------

      # Prometheus (scraping du node exporter)
      services.prometheus = {
        inherit (cfg) enable;
        inherit (cfg) retentionTime;
        scrapeConfigs = lib.optional cfg.enable {
          job_name = "node";
          static_configs = [
            { targets = map (h: "${h.vpnIp or h.ip}:${toString port.nodeExporter}") nodes; }
          ];
          scrape_interval = "15s";
        };
        globalConfig = lib.mkIf cfg.enable {
          scrape_interval = "15s";
          evaluation_interval = "15s";
        };
      };

      #--------------------------------------------------------------------------
      # Grafana
      #--------------------------------------------------------------------------

      # Grafana avec datasource + dashboard
      services.grafana = lib.mkIf cfg.enable {
        enable = true;

        settings = {
          server = {
            http_addr = params.ip;
            http_port = port.grafana;
            domain = params.fqdn;
            root_url = params.href;
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

      environment.etc = lib.mkIf cfg.enable {
        "grafana-dashboards/node-explorer.json".source = ./monitoring/node-explorer.json;
      };

      # Ouverture des ports dans le firewall
      #networking.firewall.allowedTCPPorts = [
      #  port.grafana
      #  port.nodeExporter
      #  port.prometheus
      #];
    })
  ];
}
