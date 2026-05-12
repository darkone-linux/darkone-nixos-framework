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

  # OIDC (Kanidm) — provisionnement automatique via le template
  # `darkone.service.idm.oauth2.monitoring`. Secret généré par kanidm sous le
  # nom `oidc-secret-monitoring` puis ré-alié pour Grafana (cf. mkIf cfg.enable).
  clientId = dnfLib.oauth2ClientName { name = "monitoring"; } params;
  secret = "oidc-secret-${clientId}";
  idmUrl = dnfLib.idmHref network hosts;
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
    darkone.service.monitoring.kioskTarget = lib.mkOption {
      type = lib.types.str;
      default = "d/rYdddlPWk/node-exporter-full?kiosk";
      example = "d/dnf-monitoring-home/home?kiosk";
      description = ''
        Cible (relative, sans `/`) de la redirection automatique vers Grafana
        depuis la racine du domaine monitoring. Surchargée par le module Loki
        quand il est actif pour pointer vers un dashboard d'accueil multi-source.
      '';
    };
  };

  # Prometheus + Grafana + Node Exporter
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

        # Auth gérée nativement par Grafana via OIDC (cf. settings."auth.generic_oauth").
        proxy.isProtected = false;
        proxy.isInternal = true;
        proxy.extraConfig = lib.optionalString cfg.enable "redir / /${cfg.kioskTarget}";
      };

      # Kanidm OAuth2 client template
      darkone.service.idm.oauth2.monitoring = {
        displayName = "Monitoring";
        imageFile = ./../../assets/app-icons/grafana.svg;
        redirectPaths = [ "/login/generic_oauth" ];
        landingPath = "/";
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
      # Sops
      #--------------------------------------------------------------------------

      # Secrets Grafana (clé interne) + alias du secret OIDC kanidm-owned.
      # L'admin SOPS ajoute uniquement `oidc-secret-monitoring` (chiffré pour
      # kanidm via le pattern de idm.nix). Cet alias le rend lisible par grafana.
      #
      # `optionalAttrs cfg.enable` (et non `mkIf` sur la valeur) car la clé
      # `"${secret}-service"` dépend de `params` via `clientId` ; or `params`
      # n'est résoluble que sur l'hôte qui porte le service monitoring. Sur un
      # simple monitoring-node, `optionalAttrs` court-circuite la construction
      # de la clé.
      sops.secrets = lib.optionalAttrs cfg.enable {
        grafana-secret-key = {
          mode = "0400";
          owner = "grafana";
        };
        "${secret}-service" = {
          mode = "0400";
          owner = "grafana";
          key = secret;
        };
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

      # Need network to bind the address
      systemd.services.prometheus-node-exporter = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };

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

          # https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#secret_key
          # Après mise à jour il faut rechiffrer :
          # https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-database-encryption/#re-encrypt-secrets
          security.secret_key = "$__file{${config.sops.secrets.grafana-secret-key.path}}";

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

          # SSO Kanidm (OIDC). Tout utilisateur Kanidm authentifié accède en
          # Viewer ; si le claim `groups` contient `admins` (nom court ou
          # SPN), il est promu GrafanaAdmin. La restriction stricte au groupe
          # admins (`allowed_groups`) est désactivée tant qu'on n'a pas
          # confirmé le format exact du claim côté Kanidm — voir le TODO
          # ci-dessous, possiblement via `darkone.service.idm.oauth2.monitoring.extra`
          # (claimMaps / scopeMaps custom).
          auth.disable_login_form = true;
          "auth.anonymous".enabled = false;
          "auth.generic_oauth" = {
            enabled = true;
            name = "Kanidm";
            client_id = clientId;
            client_secret = "$__file{${config.sops.secrets."${secret}-service".path}}";
            scopes = "openid email profile groups";
            auth_url = "${idmUrl}/ui/oauth2";
            token_url = "${idmUrl}/oauth2/token";
            api_url = "${idmUrl}/oauth2/openid/${clientId}/userinfo";
            role_attribute_path = "(contains(groups[*], 'admins') || contains(groups[*], 'admins@${network.domain}')) && 'GrafanaAdmin' || 'Viewer'";
            allow_sign_up = true;
            use_pkce = true;
            auto_login = true;
          };
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
