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
    diskFreePercentCrit = 7;
    memAvailablePercentWarn = 12;
    memAvailablePercentCrit = 6;
    inodeFreePercentWarn = 10;

    # Load average per core (node_load1 normalised by CPU count).
    load1PerCoreWarn = 2.0;
    load1PerCoreCrit = 4.0;
  };
in
rec {

  # Service name -> systemd unit. Only services whose unit name we are confident
  # about are listed: an unmapped service is still covered by the generic
  # `SystemdUnitFailed` rule, so this table favours precision over breadth.
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

  # Build the per-node rule groups (node up, systemd health, declared services).
  # `nodes` is the list already scraped by this zone's Prometheus; disabled
  # nodes are skipped entirely.
  mkNodeRuleGroups =
    {
      nodes,
      services,
      nodeExporterPort,
      zoneName,
    }:
    let
      watched = filter (h: nodeClass h != "disabled") nodes;

      mkNodeRules =
        host:
        let
          class = nodeClass host;
          severity = severityForClass class;
          inst = nodeInstance nodeExporterPort host;
          commonLabels = {
            inherit severity;
            zone = zoneName;
            hostname = host.hostname;
          };

          # A scraped target that stops answering: the node (or its exporter) is
          # down. `up` is the canonical liveness signal.
          nodeDown = {
            alert = "NodeDown";
            expr = ''up{job="node",instance="${inst}"} == 0'';
            "for" = "2m";
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
          ];
        }
      ];
    };

  # Network reachability rules over blackbox probes. `probes` is a list of
  # `{ name; instance; severity; job; }` describing each blackbox target so the
  # rule can name what is unreachable. Used only when network probing is on.
  mkNetworkRuleGroups =
    { probes, zoneName }:
    {
      groups = optional (probes != [ ]) {
        name = "dnf-network-${zoneName}";
        rules = map (p: {
          alert = p.alert or "ProbeFailed";
          expr = ''probe_success{job="${p.job}",instance="${p.instance}"} == 0'';
          "for" = p.for or "3m";
          labels.severity = p.severity or "warning";
          annotations = {
            summary = "${p.name} unreachable";
            description = "Blackbox probe to ${p.instance} (${p.name}) failed.";
          };
        }) probes;
      };
    };

  # Maintenance rule: a node under rebuild exports `dnf_maintenance 1` via the
  # node_exporter textfile collector, firing this alert. Alertmanager routes it
  # to a silent receiver and uses it as an inhibition source so the node's own
  # alerts are muted for the duration. No remote API call, no Alertmanager
  # exposure: the node owns its maintenance window locally.
  mkMaintenanceRuleGroups =
    { zoneName }:
    {
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

  # Merge several `{ groups = [...]; }` fragments into one rule document.
  mergeRuleGroups = fragments: { groups = lib.concatMap (f: f.groups) fragments; };

  # Convenience: full rule document for a zone's monitoring host (everything but
  # the network probes, which the caller adds when blackbox is enabled).
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
    ];
}
