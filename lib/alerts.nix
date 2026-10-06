# DNF — Prometheus alert rule generation + Alertmanager routing fragments
#
# Pure helpers that turn the network topology (the hosts scraped by a zone's
# Prometheus) into Prometheus rule groups, ready to be serialised to YAML/JSON
# and fed to `services.prometheus.rules`. The point is that alerting adapts to
# what is actually deployed: a node's class (critical/non-critical/disabled) and
# the units it runs drive both the rules emitted and their severity. All
# functions are total and side-effect free.
#
# `mkSilenceRoutes` is the odd one out: it emits Alertmanager child routes
# rather than Prometheus rules. It lives here because it is the delivery-side
# half of the same alerting story, and it is pure attrset/string logic.

{ lib, topology }:
let
  inherit (lib)
    optional
    optionalString
    filter
    hasAttr
    elem
    concatStringsSep
    escapeRegex
    ;

  # The Matrix bot renders the `host` label on the title line ("<alert> at
  # <host>") and the `description` annotation right after; `summary` never
  # reaches it, since every rule here defines a description. The raw
  # `<ip>:<port>` must therefore travel in the description to stay visible.
  instLabel = "{{ $labels.instance }}";

  # Filesystem rules aggregate per partition (cf. `byDevice`), so `device` is
  # what the description can name; `mountpoint` no longer exists on them.
  devLabel = "{{ $labels.device }}";

  # Mounts of the alerting partition: PromQL cannot concatenate label values, so
  # the Go template engine Prometheus applies to annotations fans the aggregated
  # series back out via `query`. Costs one instant query per active alert per
  # evaluation, none while the rule is silent.
  deviceMounts = ''{{ range $i, $m := sortByLabel "mountpoint" (query (printf "node_filesystem_size_bytes{instance=%q,device=%q}" $labels.instance $labels.device)) }}{{ if $i }}, {{ end }}{{ $m.Labels.mountpoint }}{{ end }}'';

  # Appended to every filesystem description, hence the leading space.
  mountsSentence = " Mounts: ${deviceMounts}.";

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

    # Remote filesystems, dropped from every filesystem rule: a client mount
    # reports the *server's* space and inodes, so watching it turns one full
    # export into the same alert on every machine that mounts it. The server is
    # scraped on its own and alerts once, with the real mountpoint. Empty the
    # list to watch a NAS that runs no node-exporter — then add its fstype to
    # `readOnlyByDesignFstypes` if it is exported read-only.
    remoteFstypes = [
      "nfs.*"
      "cifs"
      "smb.*"
      "9p"
    ];

    # Filesystem types whose read-only state is a mount option, not a failure:
    # optical/image media. `FilesystemReadOnly` skips them — nothing on the node
    # could ever clear the condition. Network shares exported `ro` are already
    # out via `remoteFstypes`. Entries are regex alternatives (PromQL label
    # matchers are fully anchored).
    readOnlyByDesignFstypes = [
      "iso9660"
      "udf"
      "erofs"
    ];
  };

  # One rule group, named `dnf-<family>-<zone>`, and the document holding it.
  group = family: zoneName: rules: {
    name = "dnf-${family}-${zoneName}";
    inherit rules;
  };
  mkGroup = family: zoneName: rules: { groups = [ (group family zoneName rules) ]; };
in
rec {

  # Service name -> primary systemd unit, for `ServiceDown`. Precision over
  # breadth: an unmapped service still has `SystemdUnitFailed`. Unmapped on
  # purpose: services fronted by a shared nginx/caddy unit (`nextcloud`,
  # `nix-cache`, `element`, `homepage`, `docs`).
  serviceUnits = {
    headscale = "headscale.service";
    tailscale = "tailscaled.service";

    # `kanidm`, not `kanidmd` (the binary): a wrong unit name exports no
    # series, and `ServiceDown` silently never fires.
    idm = "kanidm.service";

    matrix = "matrix-synapse.service";
    forgejo = "forgejo.service";
    vaultwarden = "vaultwarden.service";
    jellyfin = "jellyfin.service";
    adguardhome = "adguardhome.service";
    grafana = "grafana.service";
    immich = "immich-server.service";
    loki = "loki.service";

    # Socket-activated: the service sits `inactive` with no client (after
    # boot, while an automounted backup disk idles). The listening socket is
    # the signal; a crashed daemon still trips `SystemdUnitFailed`.
    restic = "restic-rest-server.socket";

    # Socket-activated too, `inactive` after every switch. Not probed over
    # HTTP: with no idle timeout, each scrape would pin the daemon resident.
    harmonia = "harmonia.socket";

    # Standalone daemons with a single, stable upstream unit name.
    postfix = "postfix.service";
    dnsmasq = "dnsmasq.service";
    turn = "coturn.service";
    garage = "garage.service";
    minio = "minio.service";
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

  # `,name!~"<units>"` appended inside a selector, "" for an empty denylist
  # (`config/alerts.nix`). Names are regex-escaped (RE2, anchored), then their
  # backslashes doubled: Prometheus 3 rejects `\.` in a PromQL string.
  ignoredUnitsMatcher =
    units:
    optionalString (units != [ ])
      '',name!~"${concatStringsSep "|" (map (u: lib.escape [ "\\" ] (escapeRegex u)) units)}"'';

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
  # selected by `nodeAlertEligible` are kept. `ignoredUnits` mutes the generic
  # failed-unit rule for known-broken units (cf. `ignoredUnitsMatcher`).
  mkNodeRuleGroups =
    {
      nodes,
      services,
      nodeExporterPort,
      zoneName,
      ignoredUnits ? [ ],
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

          # `host` is also set on every scrape target (cf. prometheus.nix), so
          # it is redundant here — but it keeps these rules self-sufficient and
          # unit-testable, and both carry the same value (no override conflict).
          commonLabels = {
            inherit severity reach;
            zone = zoneName;
            host = host.hostname;
          };

          # Node or exporter down (`up == 0`). WAN-reached hosts wait longer: a
          # concurrent `ZoneInternetDown` fires first and inhibits this likely
          # false alert.
          downFor = if reach == "wan" then "5m" else "2m";
          nodeDown = {
            alert = "NodeDown";
            expr = ''up{job="node",instance="${inst}"} == 0'';
            "for" = downFor;
            labels = commonLabels;
            annotations = {
              summary = "Node ${host.hostname} is down";
              description = "${host.hostname} (${inst}) has not been scrapeable for ${downFor}.";
            };
          };

          # Any systemd unit in the failed state on this node, except the ones
          # denylisted framework-wide. Catches crashes of services we do not
          # explicitly map. The failing unit is in `name`.
          systemdFailed = {
            alert = "SystemdUnitFailed";
            expr = ''node_systemd_unit_state{instance="${inst}",state="failed"${ignoredUnitsMatcher ignoredUnits}} == 1'';
            "for" = "2m";

            # A timer-driven oneshot that keeps failing leaves `failed` on each
            # retry (`activating`): without it, one fire + resolve per run.
            keep_firing_for = "30m";
            labels = commonLabels;
            annotations = {
              summary = "Failed systemd unit on ${host.hostname}";
              description = "Unit {{ $labels.name }} is failed on ${host.hostname} (${inst}).";
            };
          };

          # Declared services whose unit is not active. The `unit` label keeps
          # one rule per unit distinct: same name+labels would collide in
          # Alertmanager and fail promtool's `duplicate rule` lint.
          serviceRules = map (unit: {
            alert = "ServiceDown";
            expr = ''node_systemd_unit_state{instance="${inst}",name="${unit}",state="active"} == 0'';
            "for" = "3m";
            labels = commonLabels // {
              inherit unit;
            };
            annotations = {
              summary = "${unit} not active on ${host.hostname}";
              description = "Expected service ${unit} is not active on ${host.hostname} (${inst}).";
            };
          }) (hostExpectedUnits services host);
        in
        [
          nodeDown
          systemdFailed
        ]
        ++ serviceRules;
    in
    mkGroup "nodes" zoneName (lib.concatMap mkNodeRules watched);

  # Resource pressure rules. Generic across instances (severity is driven by the
  # threshold crossed, not the node class), so a single group covers the zone.
  mkResourceRuleGroups =
    {
      thresholds ? { },
      zoneName,
    }:
    let
      t = defaultThresholds // thresholds;

      # The node's own real filesystems: skip pseudo/ephemeral mounts that
      # legitimately run near full or report misleading sizes, and remote mounts,
      # whose metrics describe the exporting server rather than this node.
      pseudoFstypes = [
        "tmpfs"
        "ramfs"
        "overlay"
        "squashfs"
        "fuse.*"
      ];
      fsSelector = ''fstype!~"${
        concatStringsSep "|" (pseudoFstypes ++ t.remoteFstypes)
      }",mountpoint!~"/(boot|nix/store).*"'';

      # `node_filesystem_readonly` cannot tell a fault from an intent: a mount
      # made `ro` on purpose reports exactly like a disk the kernel remounted
      # after I/O errors. Only the fstype separates them, hence this extra
      # exclusion layered on `fsSelector` for that single rule.
      roSelector =
        fsSelector
        + optionalString (
          t.readOnlyByDesignFstypes != [ ]
        ) '',fstype!~"${concatStringsSep "|" t.readOnlyByDesignFstypes}"'';

      # `node_filesystem_*` is per *mount*, not per partition: one btrfs holding
      # `/`, `/nix`, `/home` and `/.swapfile` reports four identical series, so
      # a single full disk pages four times. Aggregating on `device` collapses
      # them to one alert per partition. `host`/`job` stay in the grouping — an
      # aggregation drops every label it does not group on, and losing `host`
      # retitles the Matrix message with the bare `<ip>:<port>`.
      byDevice = "instance, job, host, device, fstype";

      # `min`/`max` are no-ops on the identical values sibling mounts report;
      # they pick the alarming side should the two ever diverge.
      perDevice = op: v: "${op} by (${byDevice}) (${v})";

      diskFreeRatio = "node_filesystem_avail_bytes{${fsSelector}} / node_filesystem_size_bytes{${fsSelector}}";
      diskFreeExpr = pct: "${perDevice "min" "100 * ${diskFreeRatio}"} < ${toString pct}";
      memAvailExpr =
        pct: "100 * node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < ${toString pct}";

      # Load normalised by CPU count, so the threshold means "per core".
      loadExpr =
        n:
        ''node_load1 / on(instance) group_left count by (instance)(node_cpu_seconds_total{mode="idle"}) > ${toString n}'';
    in
    mkGroup "resources" zoneName [
      {
        alert = "DiskSpaceLow";
        expr = diskFreeExpr t.diskFreePercentWarn;
        "for" = "10m";
        labels.severity = "warning";
        annotations = {
          summary = "Low disk space on {{ $labels.instance }}";
          description = "${devLabel} below ${toString t.diskFreePercentWarn}% free on ${instLabel}.${mountsSentence}";
        };
      }
      {
        alert = "DiskSpaceCritical";
        expr = diskFreeExpr t.diskFreePercentCrit;
        "for" = "5m";
        labels.severity = "critical";
        annotations = {
          summary = "Critically low disk space on {{ $labels.instance }}";
          description = "${devLabel} below ${toString t.diskFreePercentCrit}% free on ${instLabel}.${mountsSentence}";
        };
      }
      {
        alert = "InodesLow";
        expr = "${perDevice "min" "100 * node_filesystem_files_free{${fsSelector}} / node_filesystem_files{${fsSelector}}"} < ${toString t.inodeFreePercentWarn}";
        "for" = "10m";
        labels.severity = "warning";
        annotations = {
          summary = "Low inodes on {{ $labels.instance }}";
          description = "${devLabel} below ${toString t.inodeFreePercentWarn}% free inodes on ${instLabel}.${mountsSentence}";
        };
      }
      {
        alert = "MemoryPressure";
        expr = memAvailExpr t.memAvailablePercentWarn;
        "for" = "10m";
        labels.severity = "warning";
        annotations = {
          summary = "High memory usage on {{ $labels.instance }}";
          description = "Available memory below ${toString t.memAvailablePercentWarn}% on ${instLabel}.";
        };
      }
      {
        alert = "MemoryCritical";
        expr = memAvailExpr t.memAvailablePercentCrit;
        "for" = "5m";
        labels.severity = "critical";
        annotations = {
          summary = "Critically high memory usage on {{ $labels.instance }}";
          description = "Available memory below ${toString t.memAvailablePercentCrit}% on ${instLabel}.";
        };
      }
      {
        alert = "OOMKill";
        expr = "increase(node_vmstat_oom_kill[5m]) > 0";
        "for" = "0m";
        labels.severity = "warning";
        annotations = {
          summary = "OOM kill on {{ $labels.instance }}";
          description = "The kernel OOM killer fired in the last 5m on ${instLabel}.";
        };
      }
      {
        alert = "HighLoad";
        expr = loadExpr t.load1PerCoreWarn;
        "for" = "15m";
        labels.severity = "warning";
        annotations = {
          summary = "High load on {{ $labels.instance }}";
          description = "1m load above ${toString t.load1PerCoreWarn} per core for 15m on ${instLabel}.";
        };
      }
      {
        alert = "VeryHighLoad";
        expr = loadExpr t.load1PerCoreCrit;
        "for" = "10m";
        labels.severity = "critical";
        annotations = {
          summary = "Very high load on {{ $labels.instance }}";
          description = "1m load above ${toString t.load1PerCoreCrit} per core for 10m on ${instLabel}.";
        };
      }
      {

        # A filesystem remounted read-only is almost always I/O errors or
        # corruption: page immediately. Mounts that are read-only by
        # design never reach here (cf. `roSelector`).
        alert = "FilesystemReadOnly";
        expr = "${perDevice "max" "node_filesystem_readonly{${roSelector}}"} == 1";
        "for" = "5m";
        labels.severity = "critical";
        annotations = {
          summary = "Read-only filesystem on {{ $labels.instance }}";
          description = "${devLabel} is mounted read-only on ${instLabel} (I/O errors?).${mountsSentence}";
        };
      }
      {

        # Trend-based early warning: at the current 6h slope the
        # partition fills within 24h AND is already under 40% free.
        # Catches slow leaks long before the static `DiskSpaceLow`
        # threshold.
        alert = "DiskWillFillSoon";
        expr = "${perDevice "min" "predict_linear(node_filesystem_avail_bytes{${fsSelector}}[6h], 24*3600)"} < 0 and ${perDevice "min" diskFreeRatio} < 0.4";
        "for" = "1h";
        labels.severity = "warning";
        annotations = {
          summary = "Disk filling up on {{ $labels.instance }}";
          description = "${devLabel} on ${instLabel} is projected to fill within 24h.${mountsSentence}";
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
          description = "NTP sync lost on ${instLabel}; system clock may be drifting.";
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
          description = "Connection tracking table above 80% of its limit on ${instLabel}.";
        };
      }
    ];

  # Network reachability rules over blackbox probes. `probes` is a list of
  # `{ name; instance; severity; job; }` describing each blackbox target so the
  # rule can name what is unreachable. Each probe may override `alert`, `for`,
  # `expr`, `summary`, `description` and add `labels` (e.g. `reach = "wan"`).
  # Every rule carries the zone, so Alertmanager can correlate/inhibit by zone.
  # Used only when network probing is on.
  mkNetworkRuleGroups = { probes, zoneName }: {
    groups = optional (probes != [ ]) (
      group "network" zoneName (
        map (p: {
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
        }) probes
      )
    );
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
      groups = optional (probes != [ ]) (group "http" zoneName (lib.concatMap mkRules probes));
    };

  # Backup freshness, from the restic module's textfile metrics: no metric, no
  # alert. One series per job (`backup`), so a succeeding sibling never masks
  # a failing one; `host` kept for the Matrix title. A job that never succeeded
  # ages from `dnf_restic_declared_timestamp`.
  mkResticRuleGroups =
    { zoneName }:
    let
      age = "time() - (max by (instance, backup, host) (dnf_restic_last_success_timestamp) or max by (instance, backup, host) (dnf_restic_declared_timestamp))";
    in
    mkGroup "restic" zoneName [
      {
        alert = "ResticBackupStale";
        expr = "${age} > ${toString (36 * 3600)}";
        "for" = "0m";
        labels.severity = "warning";
        annotations = {
          summary = "Restic backup stale on {{ $labels.instance }}";
          description = "No successful restic backup ({{ $labels.backup }}) on ${instLabel} for over 36h.";
        };
      }
      {
        alert = "ResticBackupCritical";
        expr = "${age} > ${toString (7 * 24 * 3600)}";
        "for" = "0m";
        labels.severity = "critical";
        annotations = {
          summary = "Restic backup critically stale on {{ $labels.instance }}";
          description = "No successful restic backup ({{ $labels.backup }}) on ${instLabel} for over 7 days.";
        };
      }
    ];

  # Maintenance rule: a node under rebuild exports `dnf_maintenance 1` via the
  # node_exporter textfile collector, firing this alert. Alertmanager routes it
  # to a silent receiver and uses it as an inhibition source so the node's own
  # alerts are muted for the duration. No remote API call, no Alertmanager
  # exposure: the node owns its maintenance window locally.
  mkMaintenanceRuleGroups =
    { zoneName }:
    mkGroup "maintenance" zoneName [
      {
        alert = "MaintenanceMode";
        expr = "dnf_maintenance == 1";
        "for" = "0m";
        labels.severity = "none";
        annotations = {
          summary = "Maintenance on {{ $labels.instance }}";
          description = "Node ${instLabel} under maintenance (rebuild in progress); its alerts are inhibited.";
        };
      }
    ];

  # Disk SMART health, from the per-node smartctl_exporter. Absent metric (no
  # SMART-capable disk, e.g. a VPS) -> no series -> no alert.
  mkSmartctlRuleGroups =
    { zoneName }:
    mkGroup "smart" zoneName [
      {

        # Overall-health self-assessment flipped to failed: the drive is
        # predicting its own death. Page.
        alert = "DiskSmartFailing";
        expr = "smartctl_device_smart_status == 0";
        "for" = "5m";
        labels.severity = "critical";
        annotations = {
          summary = "SMART failure on {{ $labels.instance }}";
          description = "Device {{ $labels.device }} on ${instLabel} reports a failing SMART overall-health status.";
        };
      }
      {
        alert = "DiskTemperatureHigh";
        expr = ''smartctl_device_temperature{temperature_type="current"} > 60'';
        "for" = "15m";
        labels.severity = "warning";
        annotations = {
          summary = "Disk temperature high on {{ $labels.instance }}";
          description = "Device {{ $labels.device }} on ${instLabel} above 60°C for 15m.";
        };
      }
    ];

  # Postfix relay health, from the postfix_exporter. Emitted only for zones that
  # actually run a relay (gated by the caller).
  mkPostfixRuleGroups =
    { zoneName }:
    mkGroup "postfix" zoneName [
      {

        # The exporter reached its target but Postfix is not answering:
        # the relay is down (mail escalation would silently fail).
        alert = "PostfixRelayUnhealthy";
        expr = "postfix_up == 0";
        "for" = "5m";
        labels.severity = "warning";
        annotations = {
          summary = "Postfix relay unhealthy on {{ $labels.instance }}";
          description = "postfix_up == 0 on ${instLabel}: the SMTP relay is not responding.";
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
          description = "More than 50 deferred messages on ${instLabel} for 30m (upstream/relay problem?).";
        };
      }
    ];

  # Matrix Synapse health, from its native Prometheus metrics. Uses the
  # prometheus_client standard `process_start_time_seconds` (stable across
  # versions) and the HTTP response counters. Emitted only for zones running a
  # homeserver (gated by the caller). `job="synapse"` isolates the listener.
  mkSynapseRuleGroups =
    { zoneName }:
    mkGroup "synapse" zoneName [
      {

        # Crash loop: more than two process starts in 30m, beyond what a
        # single planned restart explains.
        alert = "SynapseRestarting";
        expr = ''changes(process_start_time_seconds{job="synapse"}[30m]) > 2'';
        "for" = "0m";
        labels.severity = "warning";
        annotations = {
          summary = "Synapse restarting repeatedly on {{ $labels.instance }}";
          description = "matrix-synapse on ${instLabel} restarted more than twice in 30m.";
        };
      }
      {

        # Elevated server-side errors. The ratio is NaN without traffic, so
        # it stays silent on an idle homeserver. `host` is grouped on so the
        # aggregation does not drop it (cf. mkResticRuleGroups).
        alert = "SynapseHighErrorRate";
        expr = ''sum by (instance, host) (rate(synapse_http_server_responses_total{job="synapse",code=~"5.."}[15m])) / sum by (instance, host) (rate(synapse_http_server_responses_total{job="synapse"}[15m])) > 0.05'';
        "for" = "15m";
        labels.severity = "warning";
        annotations = {
          summary = "Synapse high 5xx error rate on {{ $labels.instance }}";
          description = "Over 5% of Synapse HTTP responses on ${instLabel} are 5xx for 15m.";
        };
      }
    ];

  # Tailnet self-heal health, from the `tailscale/selfheal.nix` watchdog: these
  # rules surface what a tailscaled restart cannot fix. No watchdog, no metric,
  # no alert.
  mkTailscaleRuleGroups =
    { zoneName }:
    mkGroup "tailscale" zoneName [
      {

        # The auto-restart fired repeatedly: the disconnection keeps coming
        # back, so the root cause is deeper than a stuck session. Page a human.
        alert = "TailscaleFlapping";
        expr = "increase(dnf_tailscale_selfheal_restarts_total[1h]) > 3";
        "for" = "0m";
        labels.severity = "warning";
        annotations = {
          summary = "Tailscale self-heal flapping on {{ $labels.instance }}";
          description = "tailscaled on ${instLabel} was auto-restarted more than 3 times in 1h.";
        };
      }
      {

        # Still disconnected from headscale despite the watchdog: the restart
        # did not restore the control connection.
        alert = "TailscaleUnhealthy";
        expr = "dnf_tailscale_healthy == 0";
        "for" = "10m";
        labels.severity = "warning";
        annotations = {
          summary = "Tailscale unhealthy on {{ $labels.instance }}";
          description = "tailscaled on ${instLabel} has been disconnected from headscale for 10m.";
        };
      }
    ];

  # Gateway uplink failover, from `dnf-uplink-monitor` (host/gateway.nix) via
  # the node_exporter textfile collector. Absent metric (no backup link) -> no
  # series -> no alert.
  mkUplinkRuleGroups =
    { zoneName }:
    mkGroup "uplinks" zoneName [
      {

        # Degraded but serving: the zone reaches the Internet through a
        # backup link. Warn, as a phone or 4G link is metered.
        alert = "GatewayOnBackupLink";
        expr = ''dnf_gateway_link_active{role="backup"} == 1'';
        "for" = "2m";
        labels.severity = "warning";
        annotations = {
          summary = "Gateway {{ $labels.instance }} on backup link {{ $labels.interface }}";
          description = "The zone leaves through backup link {{ $labels.interface }} on ${instLabel}: the WAN has no link, no lease or no Internet.";
        };
      }
    ];

  # Tailnet drift, from `headscale-audit` (service/headscale/audit.nix) via the
  # node_exporter textfile collector of the coordination server. Absent metric
  # (no headscale) -> no series -> no alert. Details in the unit's journal.
  mkHeadscaleRuleGroups =
    { zoneName }:
    mkGroup "headscale" zoneName [
      {

        # A declared machine is gone, mistagged or on another IP, or no
        # personal node holds an admin device IP. 30m: two audits, rides out
        # a re-registration in progress.
        alert = "HeadscaleNodeDrift";
        expr = ''max by (instance, host, node) ({__name__=~"dnf_headscale_node_(missing|tag_mismatch|ip_drift)"}) == 1'';
        "for" = "30m";
        labels.severity = "warning";
        annotations = {
          summary = "Tailnet node {{ $labels.node }} drifted from the declared topology";
          description = "Node {{ $labels.node }} is missing, mistagged or on another IP (headscale on ${instLabel}); see `journalctl -u headscale-audit`.";
        };
      }
      {

        # Tagged but undeclared, or owned by a login outside the tailnet
        # users: an enrolment the configuration never asked for.
        alert = "HeadscaleUnexpectedNode";
        expr = "dnf_headscale_unexpected_node == 1";
        "for" = "0m";
        labels.severity = "warning";
        annotations = {
          summary = "Unexpected tailnet node {{ $labels.node }}";
          description = "Node {{ $labels.node }} (owner {{ $labels.user }}) is not declared (headscale on ${instLabel}).";
        };
      }
      {

        # Served policy differs from the deployed file (failed reload), or
        # fails `headscale policy check` against the live nodes.
        alert = "HeadscalePolicyInvalid";
        expr = "dnf_headscale_policy_valid == 0";
        "for" = "30m";
        labels.severity = "warning";
        annotations = {
          summary = "Headscale policy invalid on {{ $labels.instance }}";
          description = "The ACL policy served by headscale on ${instLabel} differs from the deployed file or fails its check.";
        };
      }
      {

        # Started while Kanidm was unreachable: CLI registration only, and
        # headscale never retries OIDC before its next restart.
        alert = "HeadscaleOidcFallback";
        expr = "dnf_headscale_oidc_available == 0";
        "for" = "0m";
        labels.severity = "warning";
        annotations = {
          summary = "Headscale without OIDC on {{ $labels.instance }}";
          description = "headscale on ${instLabel} fell back to CLI registration; restart it once Kanidm is up.";
        };
      }
      {
        alert = "HeadscaleNodeExpiring";
        expr = "dnf_headscale_node_expiry_timestamp_seconds - time() < ${toString (7 * 24 * 3600)}";
        "for" = "1h";
        labels.severity = "warning";
        annotations = {
          summary = "Tailnet node {{ $labels.node }} key expiring";
          description = "Node {{ $labels.node }} (owner {{ $labels.user }}) expires within 7 days or has expired: log in again (headscale on ${instLabel}).";
        };
      }
      {

        # A failing or stopped audit silences every rule above.
        alert = "HeadscaleAuditStale";
        expr = "time() - dnf_headscale_audit_last_success_timestamp_seconds > ${toString 3600}";
        "for" = "0m";
        labels.severity = "warning";
        annotations = {
          summary = "Headscale audit stale on {{ $labels.instance }}";
          description = "headscale-audit has not succeeded on ${instLabel} for over 1h.";
        };
      }
    ];

  # Merge several `{ groups = [...]; }` fragments into one rule document.
  mergeRuleGroups = fragments: { groups = lib.concatMap (f: f.groups) fragments; };

  # Alertmanager child routes sending accepted alerts to the `null` receiver:
  # still firing and visible, never notified. ANDed matchers, `alertname`
  # always set: muting `DiskSpaceLow` leaves `DiskSpaceCritical` armed.
  # The caller MUST place them before the severity routes: first match wins.
  mkSilenceRoutes =
    silences:
    let
      quote = v: ''"${lib.escape [ "\\" "\"" ] v}"'';
    in
    map (
      s:
      let
        host = s.host or null;
      in
      {
        matchers = [
          "alertname=${quote s.alert}"
        ]
        ++ optional (host != null && host != "") "host=${quote host}"
        ++ lib.mapAttrsToList (name: value: "${name}=${quote value}") (s.matchers or { });
        receiver = "null";
      }
    ) silences;

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
      ignoredUnits ? [ ],
    }:
    mergeRuleGroups [
      (mkNodeRuleGroups {
        inherit
          nodes
          services
          nodeExporterPort
          zoneName
          ignoredUnits
          ;
      })
      (mkResourceRuleGroups { inherit thresholds zoneName; })
      (mkResticRuleGroups { inherit zoneName; })
      (mkSmartctlRuleGroups { inherit zoneName; })
      (mkTailscaleRuleGroups { inherit zoneName; })
      (mkHeadscaleRuleGroups { inherit zoneName; })
      (mkUplinkRuleGroups { inherit zoneName; })
    ];
}
