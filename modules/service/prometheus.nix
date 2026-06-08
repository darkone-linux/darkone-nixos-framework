# Prometheus monitoring server with declarative Alertmanager escalation.
#
# :::tip[Prometheus & Grafana]
# Standalone metrics + alerting service, independent from Grafana:
#
# - Scrapes every zone node carrying the `monitoring-node:<zone>` feature.
# - Alertmanager routes by severity: warning -> Matrix #warnings,
#   critical -> Matrix #incidents + mail (local Postfix relay).
# - blackbox_exporter probes gateway / tailnet / DNS reachability.
# - Node classes (critical/non-critical/disabled) come from the `alert-*`
#   features or the host profile (see `dnf/lib/alerts.nix`).
#
# `monitoring` (Grafana) requires a `prometheus` on the same host
# (enforced by the generator `require`). The web UI is exposed at
# `https://prometheus.<zone>.<domain>` behind oauth2-proxy (group `admins`),
# which also fixes the alert links pointing back to Prometheus.
# :::

{
  lib,
  config,
  dnfLib,
  dnfConfig,
  hosts,
  host,
  network,
  zone,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.prometheus;
  alerting = cfg.alerting;

  # Matrix alerting config: `admin` stays manual in config.yaml, while `bot`
  # and the room IDs are provisioned by `just configure-alert-bot` into
  # `var/generated/matrix.nix` (merged into `network` by mk-configuration.nix).
  mtx = network.matrix or { };

  # Alertmanager auto-activates once the bot rooms exist: running the bot
  # provisioning is enough, no per-host toggle. Still overridable manually.
  roomsReady = (mtx.warningsRoom or "") != "" && (mtx.incidentsRoom or "") != "";

  port = {
    prometheus = config.services.prometheus.port;
    nodeExporter = dnfConfig.network.ports.nodeExporter;
    alertmanager = dnfConfig.network.ports.alertmanager;
    matrixReceiver = dnfConfig.network.ports.matrixAlertReceiver;
    blackbox = dnfConfig.network.ports.blackboxExporter;
  };

  # Nodes supervised by the current zone (scrape targets).
  nodes = lib.filter (
    h: lib.hasAttr "monitoring-node" h.features && h.features.monitoring-node == zone.name
  ) hosts;

  # Service params: drive the protected vhost and, via `href`, the external URL
  # Prometheus stamps into alert links (`generatorURL`).
  defaultParams = {
    description = "Metrics, alerting and probes";
    icon = "prometheus";
  };
  params = dnfLib.extractServiceParams host network "prometheus" defaultParams;

  # Network reachability targets, shared by the blackbox prober (probes scraped)
  # and the network alert rules (probe_success == 0). The zone gateway and the
  # headscale coordination server are the two single points whose loss breaks
  # the zone or the tailnet. Lazy: only forced inside the alerting mkIf blocks.
  gwIp = zone.gateway.vpn.ipv4 or "";
  hcsHost = dnfLib.findHost network.coordination.hostname dnfLib.constants.globalZone hosts;
  hcsIp = hcsHost.vpnIp or "";
  dnsTarget = "${gwIp}:53";

  # One alert per probe target, named and severity-tagged: gateway/tailnet
  # losses page, a DNS miss warns.
  networkProbes =
    (lib.optional (gwIp != "") {
      name = "gateway ${zone.name} (${gwIp})";
      instance = gwIp;
      job = "blackbox-icmp";
      severity = "critical";
    })
    ++ (lib.optional (hcsIp != "") {
      name = "tailnet coordination ${network.coordination.hostname} (${hcsIp})";
      instance = hcsIp;
      job = "blackbox-icmp";
      severity = "critical";
    })
    ++ (lib.optional (gwIp != "") {
      name = "DNS resolver ${gwIp}";
      instance = dnsTarget;
      job = "blackbox-dns";
      severity = "warning";
      "for" = "5m";
    });
in
{
  options = {
    darkone.service.prometheus.enable = lib.mkEnableOption "Enable the Prometheus metrics + alerting server";

    darkone.service.prometheus.retentionTime = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      description = "Prometheus metrics retention duration";
    };

    # Alerting (Alertmanager + Matrix/email escalation). Severity drives the
    # escalation: warning -> Matrix #warnings, critical -> Matrix #incidents +
    # mail. Node class (critical/non-critical/disabled) comes from the `alert-*`
    # features or the host profile (see dnfLib alerts helpers).
    darkone.service.prometheus.alerting = {
      enable = lib.mkOption {
        type = lib.types.bool;

        # Provisioning the Matrix rooms is the activation signal.
        default = roomsReady;
        description = "Enable Alertmanager (defaults on once the Matrix alert rooms are provisioned)";
      };

      matrix = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Deliver alerts to Matrix rooms via the matrix-alertmanager bot";
        };
        userId = lib.mkOption {
          type = lib.types.str;
          default = if (mtx.bot or "") != "" then "@${mtx.bot}:${network.domain}" else "";
          example = "@alertbot:poncon.fr";
          description = "Matrix user ID of the alert bot (defaults from network.matrix.bot)";
        };
        warningsRoom = lib.mkOption {
          type = lib.types.str;
          default = mtx.warningsRoom or "";
          example = "!warnings:poncon.fr";
          description = "Matrix room ID for warnings (defaults from network.matrix.warningsRoom)";
        };
        incidentsRoom = lib.mkOption {
          type = lib.types.str;
          default = mtx.incidentsRoom or "";
          example = "!incidents:poncon.fr";
          description = "Matrix room ID for incidents (defaults from network.matrix.incidentsRoom)";
        };
      };

      email = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Also send critical alerts by mail (through the local Postfix relay)";
        };
        to = lib.mkOption {
          type = lib.types.str;
          default = "admin@${network.domain}";
          description = "Recipient of critical alert mails";
        };
      };

      network.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Probe network reachability (gateway/tailnet/DNS) with blackbox_exporter";
      };

      silenceOnRebuild = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Ship the dnf-maintenance flag (textfile collector) so rebuilds inhibit a node's alerts";
      };

      thresholds = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        example = {
          diskFreePercentWarn = 10;
        };
        description = "Override resource alert thresholds (see dnf/lib/alerts.nix defaults)";
      };
    };
  };

  config = lib.mkMerge [

    #--------------------------------------------------------------------------
    # DNF Service registration (always)
    #--------------------------------------------------------------------------

    {
      darkone.system.services.service.prometheus = {
        inherit defaultParams;
        persist.varDirs = lib.optional cfg.enable "/var/lib/prometheus2";

        # Protected vhost (oauth2-proxy + kanidm group `admins`): Prometheus has
        # no native UI auth, so the proxy is the only gate. Also makes the alert
        # links (`https://prometheus.<zone>.<domain>`) reachable after login.
        proxy.enable = cfg.enable;
        proxy.servicePort = lib.mkIf cfg.enable port.prometheus;
        proxy.isProtected = true;
        proxy.allowedGroups = [ "admins" ];
      };
    }

    #--------------------------------------------------------------------------
    # Prometheus server (scrapes the zone's node exporters)
    #--------------------------------------------------------------------------

    (lib.mkIf cfg.enable {

      # Darkone service: enable (home page + virtualhost)
      darkone.system.services = dnfLib.enableBlock "prometheus";

      services.prometheus = {
        enable = true;
        inherit (cfg) retentionTime;

        # Bind the host IP (Caddy reaches it locally); the port is never opened
        # in the firewall, so external access only goes through the proxy.
        listenAddress = params.ip;

        # External URL stamped into alert `generatorURL` links so they resolve
        # from anywhere on the network, not as `http://<host>:9090`.
        webExternalUrl = params.href;

        scrapeConfigs = [
          {
            job_name = "node";
            static_configs = [
              { targets = map (h: "${dnfLib.preferredIp h}:${toString port.nodeExporter}") nodes; }
            ];
            scrape_interval = "15s";
          }
        ];
        globalConfig = {
          scrape_interval = "15s";
          evaluation_interval = "15s";
        };
      };
    })

    #--------------------------------------------------------------------------
    # Alerting — Alertmanager + Matrix/email escalation (severity-based)
    #--------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && alerting.enable) {

      assertions = [
        {
          assertion =
            !alerting.matrix.enable
            || (
              alerting.matrix.userId != ""
              && alerting.matrix.warningsRoom != ""
              && alerting.matrix.incidentsRoom != ""
            );
          message = "darkone.service.prometheus.alerting.matrix: userId, warningsRoom and incidentsRoom are required when Matrix delivery is enabled (run `just configure-alert-bot`).";
        }
      ];

      # Critical alerts escalate to mail through the framework's local relay, so
      # it must run here: Postfix owns the 465/SASL/TLS handshake, Alertmanager
      # only talks plain SMTP to localhost.
      darkone.service.postfix.enable = lib.mkIf alerting.email.enable (lib.mkDefault true);

      # Bot access token + shared webhook secret. The same webhook secret is fed
      # to Alertmanager via env so the receiver URL it builds matches the bot.
      sops.secrets = lib.mkIf alerting.matrix.enable {
        alertmanager-matrix-token = { };
        alertmanager-webhook-secret = { };
      };
      sops.templates = lib.mkIf alerting.matrix.enable {
        alertmanager-env.content = ''
          WEBHOOK_SECRET=${config.sops.placeholder.alertmanager-webhook-secret}
        '';
      };

      # Matrix delivery bot: maps an Alertmanager receiver name to a room.
      services.matrix-alertmanager = lib.mkIf alerting.matrix.enable {
        enable = true;
        port = port.matrixReceiver;
        homeserverUrl = "https://matrix.${network.domain}";
        matrixUser = alerting.matrix.userId;
        tokenFile = config.sops.secrets.alertmanager-matrix-token.path;
        secretFile = config.sops.secrets.alertmanager-webhook-secret.path;
        matrixRooms = [
          {
            receivers = [ "matrix-warnings" ];
            roomId = alerting.matrix.warningsRoom;
          }
          {
            receivers = [ "matrix-incidents" ];
            roomId = alerting.matrix.incidentsRoom;
          }
        ];
      };

      # Alertmanager: dedup + grouping + severity routing + inhibition.
      services.prometheus.alertmanager = {
        enable = true;
        port = port.alertmanager;
        listenAddress = "127.0.0.1";
        environmentFile = lib.mkIf alerting.matrix.enable config.sops.templates.alertmanager-env.path;

        # `$WEBHOOK_SECRET` is substituted at runtime from environmentFile; the
        # build-time amtool check sees the literal, so it is disabled.
        checkConfig = false;

        configuration = {
          route = {
            group_by = [
              "alertname"
              "instance"
            ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";
            receiver = "matrix-warnings";
            routes =
              # Maintenance alerts are swallowed: they exist only to drive
              # inhibition, never to notify.
              lib.optional alerting.silenceOnRebuild {
                matchers = [ ''alertname="MaintenanceMode"'' ];
                receiver = "null";
              }
              ++ [
                {
                  matchers = [ ''severity="critical"'' ];
                  receiver = "matrix-incidents";
                }
                {
                  matchers = [ ''severity="warning"'' ];
                  receiver = "matrix-warnings";
                }
              ];
          };

          inhibit_rules =
            # A firing critical mutes the matching warning for the same target.
            [
              {
                source_matchers = [ ''severity="critical"'' ];
                target_matchers = [ ''severity="warning"'' ];
                equal = [
                  "alertname"
                  "instance"
                ];
              }
            ]
            # A node under maintenance mutes all of its own alerts.
            ++ lib.optional alerting.silenceOnRebuild {
              source_matchers = [ ''alertname="MaintenanceMode"'' ];
              target_matchers = [ ''severity=~".+"'' ];
              equal = [ "instance" ];
            };

          receivers = lib.optional alerting.silenceOnRebuild { name = "null"; } ++ [
            {
              name = "matrix-warnings";
              webhook_configs = lib.optionals alerting.matrix.enable [
                {
                  url = "http://127.0.0.1:${toString port.matrixReceiver}/alerts?secret=$WEBHOOK_SECRET";
                  send_resolved = true;
                }
              ];
            }
            {
              name = "matrix-incidents";
              webhook_configs = lib.optionals alerting.matrix.enable [
                {
                  url = "http://127.0.0.1:${toString port.matrixReceiver}/alerts?secret=$WEBHOOK_SECRET";
                  send_resolved = true;
                }
              ];
              email_configs = lib.optionals alerting.email.enable [
                {
                  to = alerting.email.to;
                  from = "alertmanager@${network.domain}";
                  smarthost = "localhost:25";
                  require_tls = false;
                  send_resolved = true;
                }
              ];
            }
          ];
        };
      };

      # Point Prometheus at the local Alertmanager and load the generated rules.
      services.prometheus.alertmanagers = [
        { static_configs = [ { targets = [ "127.0.0.1:${toString port.alertmanager}" ]; } ]; }
      ];

      # NixOS concatenates every `services.prometheus.rules` entry into ONE file;
      # multiple top-level `groups:` documents would not merge (only the first is
      # read). So fold node/resource, maintenance and network groups into a single
      # document here rather than emitting separate entries.
      services.prometheus.rules = [
        (builtins.toJSON (
          dnfLib.mergeRuleGroups (
            [
              (dnfLib.mkAlertRuleGroups {
                inherit nodes;
                services = network.services;
                nodeExporterPort = port.nodeExporter;
                zoneName = zone.name;
                inherit (alerting) thresholds;
              })
            ]
            ++ lib.optional alerting.silenceOnRebuild (dnfLib.mkMaintenanceRuleGroups { zoneName = zone.name; })
            ++ lib.optional alerting.network.enable (
              dnfLib.mkNetworkRuleGroups {
                zoneName = zone.name;
                probes = networkProbes;
              }
            )
          )
        ))
      ];
    })

    #--------------------------------------------------------------------------
    # Network reachability — blackbox probes (gateway / tailnet / DNS)
    #--------------------------------------------------------------------------

    (lib.mkIf (cfg.enable && alerting.enable && alerting.network.enable) (
      let

        # A name that must always resolve through the zone resolver; failure to
        # answer it flags a DNS problem. (Reachability targets gwIp/hcsIp/dnsTarget
        # are derived once at module scope and shared with the network rules.)
        controlName = "idm.${network.domain}";

        icmpTargets = lib.filter (x: x != "") [
          gwIp
          hcsIp
        ];

        # Blackbox prober definitions (ICMP reachability + DNS resolution).
        blackboxConfig = (pkgs.formats.yaml { }).generate "blackbox.yml" {
          modules = {
            icmp = {
              prober = "icmp";
              timeout = "5s";
              icmp.preferred_ip_protocol = "ip4";
            };
            dns = {
              prober = "dns";
              timeout = "5s";
              dns = {
                query_name = controlName;
                query_type = "A";
                preferred_ip_protocol = "ip4";
              };
            };
          };
        };

        # Standard blackbox scrape: the probed address travels as `instance`,
        # the request itself is sent to the local exporter.
        mkBlackboxJob = jobName: moduleName: targets: {
          job_name = jobName;
          metrics_path = "/probe";
          params.module = [ moduleName ];
          static_configs = [ { inherit targets; } ];
          scrape_interval = "30s";
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "127.0.0.1:${toString port.blackbox}";
            }
          ];
        };
      in
      {
        services.prometheus.exporters.blackbox = {
          enable = true;
          port = port.blackbox;
          listenAddress = "127.0.0.1";
          openFirewall = false;
          configFile = blackboxConfig;
        };

        services.prometheus.scrapeConfigs =
          (lib.optional (icmpTargets != [ ]) (mkBlackboxJob "blackbox-icmp" "icmp" icmpTargets))
          ++ (lib.optional (gwIp != "") (mkBlackboxJob "blackbox-dns" "dns" [ dnsTarget ]));
      }
    ))
  ];
}
