# Loki + Promtail module.
#
# :::tip
# Collecte centralisée des access logs Caddy, exploitée par Grafana via
# une datasource Loki provisionnée et un dashboard dédié.
#
# Pattern dual aligné sur monitoring.nix :
# - `enable`   : déploie le serveur Loki + la datasource Grafana sur le
#   même hôte que celui qui porte le service `monitoring` (Grafana).
# - `isClient` : déploie Promtail sur chaque hôte qui exécute Caddy. Les
#   logs Caddy sont attendus en JSON dans `/var/log/caddy/access-*.log`
#   (cf. `dnf/modules/system/services.nix`).
#
# Par défaut, `enable` suit `darkone.service.monitoring.enable` et
# `isClient` suit `services.caddy.enable` : l'installation est totalement
# automatique dès que le monitoring et Caddy sont actifs.
# :::

{
  lib,
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

  # Hôte qui porte le service monitoring (Grafana). On y pousse les logs.
  monitoringSvc = lib.findFirst (s: s.name == "monitoring") null network.services;
  monitoringHost =
    if monitoringSvc != null then dnfLib.findHost monitoringSvc.host monitoringSvc.zone hosts else { };
  lokiAddr = dnfLib.preferredIp monitoringHost;
  lokiUrl = "http://${lokiAddr}:${toString port.loki}";

  # Adresse de binding locale (VPN si dispo, sinon LAN).
  bindAddr = dnfLib.preferredIp host;
in
{
  options = {
    darkone.service.loki.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.darkone.service.monitoring.enable;
      description = "Déploie le serveur Loki + la datasource Grafana (colocalisé avec Grafana).";
    };
    darkone.service.loki.isClient = lib.mkOption {
      type = lib.types.bool;
      default = config.services.caddy.enable;
      description = "Déploie Promtail pour collecter les access logs Caddy locaux.";
    };
    darkone.service.loki.retentionTime = lib.mkOption {
      type = lib.types.str;
      default = "720h";
      description = "Durée de rétention des logs dans Loki (30 jours par défaut).";
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
        proxy.enable = false; # accès interne uniquement, pas de vhost Caddy
        proxy.servicePort = port.loki;
        proxy.isInternal = true;
      };
    }

    #--------------------------------------------------------------------------
    # Serveur Loki (colocalisé avec Grafana)
    #--------------------------------------------------------------------------

    (lib.mkIf cfg.enable {

      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;

          server = {
            http_listen_address = bindAddr;
            http_listen_port = port.loki;
            grpc_listen_port = 0;
          };

          common = {
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            ring = {
              kvstore.store = "inmemory";
              instance_addr = "127.0.0.1";
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

      # Datasource Loki + dashboard Caddy (mkMerge avec monitoring.nix)
      services.grafana.provision = {
        datasources.settings.datasources = [
          {
            name = "Loki";
            type = "loki";
            url = "http://127.0.0.1:${toString port.loki}";
            isDefault = false;
            editable = false;
          }
        ];
      };

      environment.etc."grafana-dashboards/caddy-access.json".source = ./loki/caddy-access.json;

      # Dashboard d'accueil + bascule de la redirection kiosk. L'utilisateur
      # arrive sur monitoring.zone.tld/, est redirigé vers ce home dashboard
      # qui liste les dashboards disponibles. mkDefault permet à l'utilisateur
      # final de surcharger la cible depuis usr/ s'il préfère un autre menu.
      environment.etc."grafana-dashboards/monitoring-home.json".source = ./loki/monitoring-home.json;
      darkone.service.monitoring.kioskTarget = lib.mkDefault "d/dnf-monitoring-home/home?kiosk";

      # Le serveur Loki écoute sur l'interface interne (VPN ou LAN selon
      # la topologie). Sur un hôte sans interface interne, le port s'ouvre
      # globalement, ce qui est sans risque puisque Loki tourne uniquement
      # sur l'hôte monitoring (typiquement le HCS, déjà filtré en amont).
      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = [ port.loki ];
      };
    })

    #--------------------------------------------------------------------------
    # Client Grafana Alloy (sur chaque hôte qui exécute Caddy)
    #
    # Promtail ayant atteint sa fin de vie, son successeur officiel
    # `grafana-alloy` joue le même rôle : tail des fichiers Caddy + parsing
    # JSON + push vers Loki. Configuration en River, déposée dans
    # `/etc/alloy/config.alloy` (chemin par défaut de `services.alloy`).
    #--------------------------------------------------------------------------

    (lib.mkIf cfg.isClient {

      services.alloy.enable = true;

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

      # Alloy tourne avec DynamicUser, on doit donc passer par les
      # SupplementaryGroups systemd pour autoriser la lecture des logs Caddy.
      systemd.services.alloy.serviceConfig.SupplementaryGroups = [ "caddy" ];
    })
  ];
}
