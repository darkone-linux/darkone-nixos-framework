# Loki + Alloy, http stats with grafana.
#
# :::note
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
#
# :::tip Débogage & nettoyage manuel
# Symptômes les plus courants après une (dés)activation de `loki` ou un
# changement de format de log côté Caddy :
#
# **1. "NO DATA" sur le dashboard Caddy alors que des requêtes arrivent.**
#    Vérifier la chaîne d'ingestion de bout en bout :
#    ```sh
#    # Sur l'hôte Caddy : Alloy tourne ? lit-il les fichiers ?
#    sudo systemctl status alloy --no-pager
#    sudo journalctl -u alloy -n 100 --no-pager | grep -iE 'error|permission'
#    ls -la /var/log/caddy/access-*.log   # doit être caddy:caddy
#
#    # Sur l'hôte monitoring : Loki reçoit-il quelque chose ?
#    # (remplacer <IP> par l'IP interne du host monitoring, Loki ne bind
#    # PAS sur 127.0.0.1 — cf. http_listen_address = bindAddr)
#    curl -s http://<IP>:3100/loki/api/v1/labels | jq
#    curl -sG http://<IP>:3100/loki/api/v1/query \
#         --data-urlencode 'query={job="caddy"}' | jq '.data.result | length'
#    ```
#
# **2. `alloy.service: mkdir data-alloy/remotecfg: permission denied`.**
#    Ownership orphelin de `/var/lib/alloy` hérité d'un ancien DynamicUser.
#    L'`ExecStartPre` du service répare normalement tout seul, mais en cas
#    de coincement (ex. unit en `start-limit-hit`) :
#    ```sh
#    sudo systemctl stop alloy
#    sudo chown -R caddy:caddy /var/lib/alloy
#    sudo systemctl reset-failed alloy
#    sudo systemctl start alloy
#    ```
#
# **3. Grafana refuse de démarrer : `Datasource provisioning error: data
#    source not found`.** Conflit d'UID en base SQLite après changement de
#    provision (typiquement passage d'un UID auto-généré à `uid = "loki"`).
#    Le `deleteDatasources` du module gère ça en théorie ; sinon, purge
#    manuelle :
#    ```sh
#    sudo systemctl stop grafana
#    sudo sqlite3 /var/lib/grafana/grafana.db \
#         "DELETE FROM data_source WHERE name='Loki';"
#    sudo systemctl reset-failed grafana
#    sudo systemctl start grafana
#    ```
#
# **4. Fichiers de logs Caddy obsolètes** (ancien nommage avec `:` ou
#    schéma, ex. `access-http:__nextcloud.log`). Inoffensifs mais polluent
#    le tail d'Alloy. À nettoyer ponctuellement après une migration :
#    ```sh
#    sudo rm /var/log/caddy/access-{http,https}:__*.log
#    sudo rm /var/log/caddy/access-:*.log     # variantes `:80`, `:443`
#    sudo systemctl reload caddy              # facultatif
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

        # `deleteDatasources` purge l'éventuelle entrée "Loki" préexistante en
        # base SQLite avant la ré-insertion : sans ça, le passage d'un UID
        # auto-généré à un UID fixe ("loki") provoque "data source not found"
        # au boot de Grafana (Grafana 11+ tente un update par UID et échoue).
        # Opération idempotente : delete-then-insert à chaque restart.
        deleteDatasources = [
          {
            name = "Loki";
            orgId = 1;
          }
        ];

        # Datasource Loki + dashboard Caddy (mkMerge avec monitoring.nix).
        # `uid = "loki"` est explicite : le dashboard caddy-access référence
        # la datasource par cet UID (cf. `"datasource": { "uid": "loki" }`
        # dans le JSON). Sans cet UID figé, Grafana en génère un aléatoire et
        # tous les panneaux affichent "datasource not found".
        datasources = [
          {
            name = "Loki";
            type = "loki";
            uid = "loki";

            # Loki bind sur `lokiAddr` (cf. http_listen_address ci-dessus), pas
            # sur 127.0.0.1. Grafana tourne sur le même hôte mais doit donc
            # cibler la même IP que celle utilisée pour le bind (ip interne de la zone).
            url = "http://${lokiAddr}:${toString port.loki}";
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

      # Désactive le rapport d'usage vers stats.grafana.org : sinon Alloy
      # tente toutes les ~4h de POSTer un payload de télémétrie externe.
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

      # On fait tourner Alloy directement en `caddy:caddy` (au lieu du
      # DynamicUser par défaut). Raison : Caddy crée ses access logs en mode
      # `0600` (valeur hardcodée dans son writer Go, sans surcharge possible
      # depuis le Caddyfile), donc même en ajoutant Alloy au groupe `caddy`
      # via SupplementaryGroups, le mode 0600 bloque toute lecture de groupe.
      # En devenant propriétaire des fichiers, Alloy peut les tailer.
      # `mkForce` est nécessaire pour écraser les défauts du module amont.
      systemd.services.alloy.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "caddy";
        Group = lib.mkForce "caddy";
        SupplementaryGroups = lib.mkForce [ "systemd-journal" ];

        # `ExecStartPre` (préfixe `+` ⇒ exécuté en root, indépendamment de `User=`)
        # garantit que `/var/lib/alloy` et son contenu (notamment `data-alloy/`
        # créé par Alloy lui-même) appartiennent bien à `caddy:caddy` à chaque
        # démarrage. Sans ça, sur un hôte neuf ou un hôte migré depuis l'ancien
        # DynamicUser, on tombe sur `mkdir data-alloy/remotecfg: permission
        # denied` parce que le StateDirectory de systemd ne chown pas
        # récursivement et que tmpfiles ne tourne qu'au boot (pas au switch).
        ExecStartPre = [ "+${pkgs.coreutils}/bin/chown -R caddy:caddy /var/lib/alloy" ];
      };
    })
  ];
}
