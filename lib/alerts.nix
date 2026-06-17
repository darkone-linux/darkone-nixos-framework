# DNF — Prometheus alert rule generation
#
# Pure helpers that turn the network topology (the hosts scraped by a zone's
# Prometheus) into Prometheus rule groups, ready to be serialised to YAML/JSON
# and fed to `services.prometheus.rules`. The point is that alerting adapts to
# what is actually deployed: a node's class (critical/non-critical/disabled) and
# the units it runs drive both the rules emitted and their severity. All
# functions are total and side-effect free.

{ lib, topology }:
let
  inherit (lib)
    optional
    filter
    hasAttr
    elem
    ;

  # Profiles considered critical by default when no explicit `alert-*` feature
  # overrides the node class. A down gateway/HCS/server escalates; a laptop or
  # desktop does not.
  criticalProfiles = [
    "gateway"
    "hcs"
    "server"
  ];

  # Resource thresholds. Severity is threshold-driven (not node-class driven):
  # a disk filling up is a warning everywhere, a near-full disk an incident
  # everywhere. Callers may override any field.
  defaultThresholds = {

    # Free space / memory below which we warn, then page (percent).
    diskFreePercentWarn = 15;
    diskFreePercentCrit = 5;
    memAvailablePercentWarn = 12;
    memAvailablePercentCrit = 6;
    inodeFreePercentWarn = 10;

    # Load average per core (node_load1 normalised by CPU count).
    load1PerCoreWarn = 2.0;
    load1PerCoreCrit = 4.0;
  };
in
rec {

  # Service name -> primary systemd unit (the daemon whose loss means the
  # service is down). Only units whose name we are confident about are listed:
  # an unmapped service is still covered by the generic `SystemdUnitFailed`
  # rule, so this table favours precision over breadth.
  #
  # :::note[Intentionally unmapped]
  # nginx/static-fronted services (`nextcloud`, `nix-cache`, `element`,
  # `homepage`, `docs`) share `nginx.service`/`caddy.service`: a per-service
  # `ServiceDown` would be ambiguous, so they rely on the generic rule.
  # :::
  serviceUnits = {
    headscale = "headscale.service";
    tailscale = "tailscaled.service";
    idm = "kanidmd.service";
    matrix = "matrix-synapse.service";
    forgejo = "forgejo.service";
    vaultwarden = "vaultwarden.service";
    jellyfin = "jellyfin.service";
    adguardhome = "adguardhome.service";
    grafana = "grafana.service";
    immich = "immich-server.service";
    loki = "loki.service";
    restic = "restic-rest-server.service";

    # Standalone daemons with a single, stable upstream unit name.
    postfix = "postfix.service";
    dnsmasq = "dnsmasq.service";
    turn = "coturn.service";
    garage = "garage.service";
    minio = "minio.service";
    harmonia = "harmonia.service";
    outline = "outline.service";
    mealie = "mealie.service";
    searx = "searx.service";
    geneweb = "geneweb.service";
    oxicloud = "oxicloud.service";
    home-assistant = "home-assistant.service";
    ai = "open-webui.service";

    # Server role only; an NFS client exposes an automount, not this unit, so
    # the rule simply yields no series (no false alert) on clients.
    nfs = "nfs-server.service";
  };

  # Node alert class, in priority order: an explicit `alert-*` feature wins over
  # the profile default. `disabled` means "emit no node-level alerts at all".
  nodeClass =
    host:
    let
      features = host.features or { };
      profile = host.profile or "";
    in
    if features ? "alert-disabled" then
      "disabled"
    else if features ? "alert-critical" then
      "critical"
    else if features ? "alert-non-critical" then
      "noncritical"
    else if elem profile criticalProfiles then
      "critical"
    else
      "noncritical";

  # Severity a node-scoped alert carries given its class: a critical node pages
  # (incidents room + mail), a non-critical one only warns.
  severityForClass = class: if class == "critical" then "critical" else "warning";

  # Prometheus `instance` label of a node's node_exporter target, matching the
  # scrape target built in monitoring.nix (`<preferredIp>:<port>`).
  nodeInstance = nodeExporterPort: host: "${topology.preferredIp host}:${toString nodeExporterPort}";

  # Expected service names running on a host: union of the host's declared
  # `services` attrset keys and the network-level service instances pinned to
  # that host. Only those present in `serviceUnits` yield a targeted rule.
  hostExpectedUnits =
    services: host:
    let
      fromHost = lib.attrNames (host.services or { });
      fromNetwork = map (s: s.name) (filter (s: s.host == host.hostname) services);
      names = lib.unique (fromHost ++ fromNetwork);
    in
    map (n: serviceUnits.${n}) (filter (n: hasAttr n serviceUnits) names);

  # Whether a node emits node-level alerts at all. Selection is opt-out for
  # infrastructure and must-stay-up workloads, opt-in for the rest: a host is
  # watched only if it is a network node/server (`critical` class), carries an
  # explicit `alert-non-critical` feature, or runs at least one mapped service.
  # Bare laptops/desktops with no watched service stay silent. `alert-disabled`
  # always wins (handled upstream by `nodeClass`).
  nodeAlertEligible =
    { services }:
    host:
    let
      class = nodeClass host;
      features = host.features or { };
    in
    class != "disabled"
    && (
      class == "critical" || features ? "alert-non-critical" || hostExpectedUnits services host != [ ]
    );

  # Build the per-node rule groups (node up, systemd health, declared services).
  # `nodes` is the list already scraped by this zone's Prometheus; only nodes
  # selected by `nodeAlertEligible` are kept.
  mkNodeRuleGroups =
    {
      nodes,
      services,
      nodeExporterPort,
      zoneName,
    }:
    let
      watched = filter (h: nodeAlertEligible { inherit services; } h) nodes;

      mkNodeRules =
        host:
        let
          class = nodeClass host;
          severity = severityForClass class;
          inst = nodeInstance nodeExporterPort host;

          # `reach` distinguishes hosts on this Prometheus's own zone (LAN,
          # internet-independent) from hosts joined only across the WAN/tailnet
          # (other zones, e.g. the HCS). It lets Alertmanager inhibit the
          # `wan` hosts' down-alerts when the zone's own internet is down,
          # instead of misreporting them as individually down.
          reach = if (host.zone or "") == zoneName then "local" else "wan";

          commonLabels = {
            inherit severity reach;
            zone = zoneName;
            hostname = host.hostname;
          };

          # A scraped target that stops answering: the node (or its exporter) is
          # down. `up` is the canonical liveness signal. WAN-reached hosts wait
          # a little longer so a concurrent `ZoneInternetDown` declares first
          # and inhibits this (likely false) per-host alert.
          nodeDown = {
            alert = "NodeDown";
            expr = ''up{job="node",instance="${inst}"} == 0'';
            "for" = if reach == "wan" then "5m" else "2m";
            labels = commonLabels;
            annotations = {
              summary = "Node ${host.hostname} is down";
              description = "${host.hostname} (${inst}) has not been scrapeable for 2m.";
            };
          };

          # Any systemd unit in the failed state on this node. Catches crashes of
          # services we do not explicitly map. The failing unit is in `name`.
          systemdFailed = {
            alert = "SystemdUnitFailed";
            expr = ''node_systemd_unit_state{instance="${inst}",state="failed"} == 1'';
            "for" = "2m";
            labels = commonLabels;
            annotations = {
              summary = "Failed systemd unit on ${host.hostname}";
              description = "Unit {{ $labels.name }} is failed on ${host.hostname}.";
            };
          };

          # Declared services whose expected unit is not active: enabled but not
          # running. Complements the generic failed-unit rule for the services
          # that matter most.
          serviceRules = map (unit: {
            alert = "ServiceDown";
            expr = ''node_systemd_unit_state{instance="${inst}",name="${unit}",state="active"} == 0'';
            "for" = "3m";
            labels = commonLabels;
            annotations = {
              summary = "${unit} not active on ${host.hostname}";
              description = "Expected service ${unit} is not active on ${host.hostname}.";
            };
          }) (hostExpectedUnits services host);
        in
        [
          nodeDown
          systemdFailed
        ]
        ++ serviceRules;
    in
    {
      groups = [
        {
          name = "dnf-nodes-${zoneName}";
          rules = lib.concatMap mkNodeRules watched;
        }
      ];
    };

  # Resource pressure rules. Generic across instances (severity is driven by the
  # threshold crossed, not the node class), so a single group covers the zone.
  mkResourceRuleGroups =
    {
      thresholds ? { },
      zoneName,
    }:
    let
      t = defaultThresholds // thresholds;

      # Real filesystems only: skip pseudo/ephemeral mounts that legitimately run
      # near full or report misleading sizes.
      fsSelector = ''fstype!~"tmpfs|ramfs|overlay|squashfs|fuse.*",mountpoint!~"/(boot|nix/store).*"'';
      diskFreeExpr =
        pct:
        "100 * node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}} < ${toString pct}";
      memAvailExpr =
        pct: "100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < ${toString pct}";

      # Load normalised by CPU count, so the threshold means "per core".
      loadExpr =
        n:
        ''node_load1 / on(instance) group_left count by (instance)(node_cpu_seconds_total{mode="idle"}) > ${toString n}'';
    in
    {
      groups = [
        {
          name = "dnf-resources-${zoneName}";
          rules = [
            {
              alert = "DiskSpaceLow";
              expr = diskFreeExpr t.diskFreePercentWarn;
              "for" = "10m";
              labels.severity = "warning";
              annotations = {
                summary = "Low disk space on {{ $labels.instance }}";
                description = "{{ $labels.mountpoint }} below ${toString t.diskFreePercentWarn}% free.";
              };
            }
            {
              alert = "DiskSpaceCritical";
              expr = diskFreeExpr t.diskFreePercentCrit;
              "for" = "5m";
              labels.severity = "critical";
              annotations = {
                summary = "Critically low disk space on {{ $labels.instance }}";
                description = "{{ $labels.mountpoint }} below ${toString t.diskFreePercentCrit}% free.";
              };
            }
            {
              alert = "InodesLow";
              expr = "100 * node_filesystem_files_free{${fsSelector}} / node_filesystem_files{${fsSelector}} < ${toString t.inodeFreePercentWarn}";
              "for" = "10m";
              labels.severity = "warning";
              annotations = {
                summary = "Low inodes on {{ $labels.instance }}";
                description = "{{ $labels.mountpoint }} below ${toString t.inodeFreePercentWarn}% free inodes.";
              };
            }
            {
              alert = "MemoryPressure";
              expr = memAvailExpr t.memAvailablePercentWarn;
              "for" = "10m";
              labels.severity = "warning";
              annotations = {
                summary = "High memory usage on {{ $labels.instance }}";
                description = "Available memory below ${toString t.memAvailablePercentWarn}%.";
              };
            }
            {
              alert = "MemoryCritical";
              expr = memAvailExpr t.memAvailablePercentCrit;
              "for" = "5m";
              labels.severity = "critical";
              annotations = {
                summary = "Critically high memory usage on {{ $labels.instance }}";
                description = "Available memory below ${toString t.memAvailablePercentCrit}%.";
              };
            }
            {
              alert = "OOMKill";
              expr = "increase(node_vmstat_oom_kill[5m]) > 0";
              "for" = "0m";
              labels.severity = "warning";
              annotations = {
                summary = "OOM kill on {{ $labels.instance }}";
                description = "The kernel OOM killer fired in the last 5m.";
              };
            }
            {
              alert = "HighLoad";
              expr = loadExpr t.load1PerCoreWarn;
              "for" = "15m";
              labels.severity = "warning";
              annotations = {
                summary = "High load on {{ $labels.instance }}";
                description = "1m load above ${toString t.load1PerCoreWarn} per core for 15m.";
              };
            }
            {
              alert = "VeryHighLoad";
              expr = loadExpr t.load1PerCoreCrit;
              "for" = "10m";
              labels.severity = "critical";
              annotations = {
                summary = "Very high load on {{ $labels.instance }}";
                description = "1m load above ${toString t.load1PerCoreCrit} per core for 10m.";
              };
            }
            {

              # A filesystem remounted read-only is almost always I/O errors or
              # corruption: page immediately.
              alert = "FilesystemReadOnly";
              expr = "node_filesystem_readonly{${fsSelector}} == 1";
              "for" = "5m";
              labels.severity = "critical";
              annotations = {
                summary = "Read-only filesystem on {{ $labels.instance }}";
                description = "{{ $labels.mountpoint }} is mounted read-only (I/O errors?).";
              };
            }
            {

              # Trend-based early warning: at the current 6h slope the mount
              # fills within 24h AND is already under 40% free. Catches slow
              # leaks long before the static `DiskSpaceLow` threshold.
              alert = "DiskWillFillSoon";
              expr = "predict_linear(node_filesystem_avail_bytes{${fsSelector}}[6h], 24*3600) < 0 and node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}} < 0.4";
              "for" = "1h";
              labels.severity = "warning";
              annotations = {
                summary = "Disk filling up on {{ $labels.instance }}";
                description = "{{ $labels.mountpoint }} is projected to fill within 24h.";
              };
            }
            {

              # NTP not synchronised: skews logs, certs and tokens across the
              # fleet. The metric is absent without the timex collector, so this
              # only fires where it is available.
              alert = "ClockSkew";
              expr = "node_timex_sync_status == 0";
              "for" = "10m";
              labels.severity = "warning";
              annotations = {
                summary = "Clock not synchronised on {{ $labels.instance }}";
                description = "NTP sync lost; system clock may be drifting.";
              };
            }
            {

              # Conntrack table near saturation drops new connections. Only
              # gateways/routers export this metric, so it no-ops elsewhere.
              alert = "ConntrackNearFull";
              expr = "node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8";
              "for" = "10m";
              labels.severity = "warning";
              annotations = {
                summary = "Conntrack table near full on {{ $labels.instance }}";
                description = "Connection tracking table above 80% of its limit.";
              };
            }
          ];
        }
      ];
    };

  # Network reachability rules over blackbox probes. `probes` is a list of
  # `{ name; instance; severity; job; }` describing each blackbox target so the
  # rule can name what is unreachable. Each probe may override `alert`, `for`,
  # `expr`, `summary`, `description` and add `labels` (e.g. `reach = "wan"`).
  # Every rule carries the zone, so Alertmanager can correlate/inhibit by zone.
  # Used only when network probing is on.
  mkNetworkRuleGroups = { probes, zoneName }: {
    groups = optional (probes != [ ]) {
      name = "dnf-network-${zoneName}";
      rules = map (p: {
        alert = p.alert or "ProbeFailed";
        expr = p.expr or ''probe_success{job="${p.job}",instance="${p.instance}"} == 0'';
        "for" = p.for or "3m";
        labels = {
          severity = p.severity or "warning";
          zone = zoneName;
        }
        // (p.labels or { });
        annotations = {
          summary = p.summary or "${p.name} unreachable";
          description = p.description or "Blackbox probe to ${p.instance} (${p.name}) failed.";
        };
      }) probes;
    };
  };

  # HTTP service-endpoint health + TLS certificate expiry over blackbox HTTP
  # probes. `probes` is a list of `{ name; instance(=url); labels?; }` (the
  # `reach` label lets `ZoneInternetDown` inhibit WAN-served endpoints). Cert
  # rules use a long `for` to ride out brief probe blips.
  mkHttpRuleGroups =
    { probes, zoneName }:
    let
      mkRules =
        p:
        let
          selector = ''job="blackbox-http",instance="${p.instance}"'';
          base = {
            zone = zoneName;
          }
          // (p.labels or { });
        in
        [
          {
            alert = "ServiceEndpointDown";
            expr = "probe_success{${selector}} == 0";
            "for" = "5m";
            labels = base // {
              severity = "warning";
            };
            annotations = {
              summary = "${p.name} endpoint unreachable";
              description = "HTTP probe to ${p.instance} (${p.name}) failed for 5m.";
            };
          }
          {
            alert = "CertificateExpiringSoon";
            expr = "probe_ssl_earliest_cert_expiry{${selector}} - time() < ${toString (14 * 24 * 3600)}";
            "for" = "1h";
            labels = base // {
              severity = "warning";
            };
            annotations = {
              summary = "TLS certificate for ${p.name} expiring";
              description = "Certificate for ${p.instance} expires in under 14 days.";
            };
          }
          {
            alert = "CertificateExpiringCritical";
            expr = "probe_ssl_earliest_cert_expiry{${selector}} - time() < ${toString (3 * 24 * 3600)}";
            "for" = "1h";
            labels = base // {
              severity = "critical";
            };
            annotations = {
              summary = "TLS certificate for ${p.name} expiring imminently";
              description = "Certificate for ${p.instance} expires in under 3 days.";
            };
          }
        ];
    in
    {
      groups = optional (probes != [ ]) {
        name = "dnf-http-${zoneName}";
        rules = lib.concatMap mkRules probes;
      };
    };

  # Backup freshness, driven by `dnf_restic_last_success_timestamp` (epoch of
  # the last successful restic backup), exported by the restic module via the
  # node_exporter textfile collector. Absent metric -> no series -> no alert,
  # so a host without backups never trips this.
  mkResticRuleGroups = { zoneName }: {
    groups = [
      {
        name = "dnf-restic-${zoneName}";
        rules = [
          {
            alert = "ResticBackupStale";
            expr = "time() - max by (instance, job) (dnf_restic_last_success_timestamp) > ${toString (36 * 3600)}";
            "for" = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Restic backup stale on {{ $labels.instance }}";
              description = "No successful restic backup ({{ $labels.job }}) for over 36h.";
            };
          }
          {
            alert = "ResticBackupCritical";
            expr = "time() - max by (instance, job) (dnf_restic_last_success_timestamp) > ${toString (7 * 24 * 3600)}";
            "for" = "0m";
            labels.severity = "critical";
            annotations = {
              summary = "Restic backup critically stale on {{ $labels.instance }}";
              description = "No successful restic backup ({{ $labels.job }}) for over 7 days.";
            };
          }
        ];
      }
    ];
  };

  # Maintenance rule: a node under rebuild exports `dnf_maintenance 1` via the
  # node_exporter textfile collector, firing this alert. Alertmanager routes it
  # to a silent receiver and uses it as an inhibition source so the node's own
  # alerts are muted for the duration. No remote API call, no Alertmanager
  # exposure: the node owns its maintenance window locally.
  mkMaintenanceRuleGroups = { zoneName }: {
    groups = [
      {
        name = "dnf-maintenance-${zoneName}";
        rules = [
          {
            alert = "MaintenanceMode";
            expr = "dnf_maintenance == 1";
            "for" = "0m";
            labels.severity = "none";
            annotations = {
              summary = "Maintenance on {{ $labels.instance }}";
              description = "Node under maintenance (rebuild in progress); its alerts are inhibited.";
            };
          }
        ];
      }
    ];
  };

  # Disk SMART health, from the per-node smartctl_exporter. Absent metric (no
  # SMART-capable disk, e.g. a VPS) -> no series -> no alert.
  mkSmartctlRuleGroups = { zoneName }: {
    groups = [
      {
        name = "dnf-smart-${zoneName}";
        rules = [
          {

            # Overall-health self-assessment flipped to failed: the drive is
            # predicting its own death. Page.
            alert = "DiskSmartFailing";
            expr = "smartctl_device_smart_status == 0";
            "for" = "5m";
            labels.severity = "critical";
            annotations = {
              summary = "SMART failure on {{ $labels.instance }}";
              description = "Device {{ $labels.device }} reports a failing SMART overall-health status.";
            };
          }
          {
            alert = "DiskTemperatureHigh";
            expr = ''smartctl_device_temperature{temperature_type="current"} > 60'';
            "for" = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "Disk temperature high on {{ $labels.instance }}";
              description = "Device {{ $labels.device }} above 60°C for 15m.";
            };
          }
        ];
      }
    ];
  };

  # Postfix relay health, from the postfix_exporter. Emitted only for zones that
  # actually run a relay (gated by the caller).
  mkPostfixRuleGroups = { zoneName }: {
    groups = [
      {
        name = "dnf-postfix-${zoneName}";
        rules = [
          {

            # The exporter reached its target but Postfix is not answering:
            # the relay is down (mail escalation would silently fail).
            alert = "PostfixRelayUnhealthy";
            expr = "postfix_up == 0";
            "for" = "5m";
            labels.severity = "warning";
            annotations = {
              summary = "Postfix relay unhealthy on {{ $labels.instance }}";
              description = "postfix_up == 0: the SMTP relay is not responding.";
            };
          }
          {

            # Deferred mail piling up: relay/credentials/upstream issue. The
            # metric name follows postfix_exporter's showq histogram.
            alert = "PostfixDeferredQueueHigh";
            expr = ''postfix_showq_message_size_bytes_count{queue="deferred"} > 50'';
            "for" = "30m";
            labels.severity = "warning";
            annotations = {
              summary = "Postfix deferred queue high on {{ $labels.instance }}";
              description = "More than 50 deferred messages for 30m (upstream/relay problem?).";
            };
          }
        ];
      }
    ];
  };

  # Matrix Synapse health, from its native Prometheus metrics. Uses the
  # prometheus_client standard `process_start_time_seconds` (stable across
  # versions) and the HTTP response counters. Emitted only for zones running a
  # homeserver (gated by the caller). `job="synapse"` isolates the listener.
  mkSynapseRuleGroups = { zoneName }: {
    groups = [
      {
        name = "dnf-synapse-${zoneName}";
        rules = [
          {

            # Crash loop: more than two process starts in 30m, beyond what a
            # single planned restart explains.
            alert = "SynapseRestarting";
            expr = ''changes(process_start_time_seconds{job="synapse"}[30m]) > 2'';
            "for" = "0m";
            labels.severity = "warning";
            annotations = {
              summary = "Synapse restarting repeatedly on {{ $labels.instance }}";
              description = "matrix-synapse restarted more than twice in 30m.";
            };
          }
          {

            # Elevated server-side errors. The ratio is NaN without traffic, so
            # it stays silent on an idle homeserver.
            alert = "SynapseHighErrorRate";
            expr = ''sum by (instance) (rate(synapse_http_server_responses_total{job="synapse",code=~"5.."}[15m])) / sum by (instance) (rate(synapse_http_server_responses_total{job="synapse"}[15m])) > 0.05'';
            "for" = "15m";
            labels.severity = "warning";
            annotations = {
              summary = "Synapse high 5xx error rate on {{ $labels.instance }}";
              description = "Over 5% of Synapse HTTP responses are 5xx for 15m.";
            };
          }
        ];
      }
    ];
  };

  # Merge several `{ groups = [...]; }` fragments into one rule document.
  mergeRuleGroups = fragments: { groups = lib.concatMap (f: f.groups) fragments; };

  # Convenience: full rule document for a zone's monitoring host (everything but
  # the blackbox probes — network/HTTP — which the caller adds when blackbox is
  # enabled). Restic freshness is always included: it is metric-driven and
  # no-ops where no backup metric exists.
  mkAlertRuleGroups =
    {
      nodes,
      services,
      nodeExporterPort,
      zoneName,
      thresholds ? { },
    }:
    mergeRuleGroups [
      (mkNodeRuleGroups {
        inherit
          nodes
          services
          nodeExporterPort
          zoneName
          ;
      })
      (mkResourceRuleGroups { inherit thresholds zoneName; })
      (mkResticRuleGroups { inherit zoneName; })
      (mkSmartctlRuleGroups { inherit zoneName; })
    ];
}
