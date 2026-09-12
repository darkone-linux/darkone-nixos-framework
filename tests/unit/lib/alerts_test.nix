# Tests for dnf/lib/alerts.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  critServer = {
    hostname = "srv1";
    profile = "server";
    ip = "10.0.0.1";
    features = { };
    services = { };
  };

  laptopDisabled = {
    hostname = "lap1";
    profile = "laptop";
    ip = "10.0.0.2";
    features = {
      "alert-disabled" = "ag";
    };
    services = { };
  };

  # Rules emitted for a single same-zone node, in order: nodeDown, systemdFailed,
  # then the per-service rules (none here: no declared service).
  nodeRules =
    ignoredUnits:
    (builtins.head
      (dnfLib.mkNodeRuleGroups {
        nodes = [
          {
            hostname = "a";
            profile = "server";
            ip = "10.0.0.9";
            zone = "ag";
            features = { };
            services = { };
          }
        ];
        services = [ ];
        nodeExporterPort = 9100;
        zoneName = "ag";
        inherit ignoredUnits;
      }).groups
    ).rules;

  # One zone-wide resource rule, picked by alert name.
  resourceRule =
    thresholds: alert:
    builtins.head (
      builtins.filter (r: r.alert == alert)
        (builtins.head
          (dnfLib.mkResourceRuleGroups {
            inherit thresholds;
            zoneName = "ag";
          }).groups
        ).rules
    );

  # Shared filesystem selector: the node's own real mounts only (no pseudo
  # filesystem, no remote share).
  fsSel = ''fstype!~"tmpfs|ramfs|overlay|squashfs|fuse.*|nfs.*|cifs|smb.*|9p",mountpoint!~"/(boot|nix/store).*"'';

  # Filesystem rules alert once per partition: the per-mount series are
  # collapsed on `device`. `mountpoint` is deliberately out of the grouping,
  # `host`/`job` deliberately in it (the Matrix bot titles on `host`).
  perDev = op: v: "${op} by (instance, job, host, device, fstype) (${v})";

  # Trailing sentence of every filesystem description: PromQL cannot
  # concatenate label values, so the mounts are resolved by the annotation
  # template while the alert is active.
  mountsSentence = ''Mounts: {{ range $i, $m := sortByLabel "mountpoint" (query (printf "node_filesystem_size_bytes{instance=%q,device=%q}" $labels.instance $labels.device)) }}{{ if $i }}, {{ end }}{{ $m.Labels.mountpoint }}{{ end }}.'';
in
{

  # ----- nodeClass -----
  testNodeClassFeatureCritical = {
    expr = dnfLib.nodeClass {
      profile = "laptop";
      features = {
        "alert-critical" = "ag";
      };
    };
    expected = "critical";
  };
  testNodeClassFeatureDisabled = {
    expr = dnfLib.nodeClass {
      profile = "server";
      features = {
        "alert-disabled" = "ag";
      };
    };
    expected = "disabled";
  };
  testNodeClassFeatureNonCriticalOverridesProfile = {
    expr = dnfLib.nodeClass {
      profile = "server";
      features = {
        "alert-non-critical" = "ag";
      };
    };
    expected = "noncritical";
  };
  testNodeClassProfileCriticalDefault = {
    expr = dnfLib.nodeClass {
      profile = "server";
      features = { };
    };
    expected = "critical";
  };
  testNodeClassProfileNonCriticalDefault = {
    expr = dnfLib.nodeClass {
      profile = "laptop";
      features = { };
    };
    expected = "noncritical";
  };

  # ----- severityForClass -----
  testSeverityCritical = {
    expr = dnfLib.severityForClass "critical";
    expected = "critical";
  };
  testSeverityNonCritical = {
    expr = dnfLib.severityForClass "noncritical";
    expected = "warning";
  };

  # ----- hostExpectedUnits -----
  # Unions host.services keys with network service instances pinned to the host,
  # keeping only those mapped in serviceUnits.
  testHostExpectedUnits = {
    expr =
      dnfLib.hostExpectedUnits
        [
          {
            name = "matrix";
            host = "h1";
            zone = "ag";
          }
          {
            name = "unknownsvc";
            host = "h1";
            zone = "ag";
          }
        ]
        {
          hostname = "h1";
          services = {
            headscale = { };
          };
        };
    expected = [
      "headscale.service"
      "matrix-synapse.service"
    ];
  };

  # ----- mkAlertRuleGroups -----
  # Six groups (nodes + resources + restic + smartctl + tailscale + headscale);
  # the disabled laptop is dropped, leaving a single watched node with
  # node-down + systemd-failed rules.
  testRuleGroupsCount = {
    expr =
      builtins.length
        (dnfLib.mkAlertRuleGroups {
          nodes = [
            critServer
            laptopDisabled
          ];
          services = [ ];
          nodeExporterPort = 9100;
          zoneName = "ag";
        }).groups;
    expected = 6;
  };
  testNodeGroupName = {
    expr =
      (builtins.elemAt
        (dnfLib.mkAlertRuleGroups {
          nodes = [
            critServer
            laptopDisabled
          ];
          services = [ ];
          nodeExporterPort = 9100;
          zoneName = "ag";
        }).groups
        0
      ).name;
    expected = "dnf-nodes-ag";
  };
  testWatchedNodeRulesCount = {
    expr =
      builtins.length
        (builtins.elemAt
          (dnfLib.mkAlertRuleGroups {
            nodes = [
              critServer
              laptopDisabled
            ];
            services = [ ];
            nodeExporterPort = 9100;
            zoneName = "ag";
          }).groups
          0
        ).rules;
    expected = 2;
  };
  testNodeDownExpr = {
    expr =
      (builtins.head
        (builtins.elemAt
          (dnfLib.mkAlertRuleGroups {
            nodes = [ critServer ];
            services = [ ];
            nodeExporterPort = 9100;
            zoneName = "ag";
          }).groups
          0
        ).rules
      ).expr;
    expected = ''up{job="node",instance="10.0.0.1:9100"} == 0'';
  };

  # ----- mkNetworkRuleGroups -----
  testNetworkProbeExpr = {
    expr =
      (builtins.head
        (builtins.head
          (dnfLib.mkNetworkRuleGroups {
            zoneName = "ag";
            probes = [
              {
                name = "gateway ag";
                instance = "100.64.0.1";
                job = "blackbox-icmp";
                severity = "critical";
              }
            ];
          }).groups
        ).rules
      ).expr;
    expected = ''probe_success{job="blackbox-icmp",instance="100.64.0.1"} == 0'';
  };
  testNetworkEmptyProbes = {
    expr =
      (dnfLib.mkNetworkRuleGroups {
        zoneName = "ag";
        probes = [ ];
      }).groups;
    expected = [ ];
  };

  # ----- mkMaintenanceRuleGroups -----
  testMaintenanceExpr = {
    expr =
      (builtins.head (builtins.head (dnfLib.mkMaintenanceRuleGroups { zoneName = "ag"; }).groups).rules)
      .expr;
    expected = "dnf_maintenance == 1";
  };

  # ----- serviceUnits (extended mapping) -----
  testServiceUnitPostfix = {
    expr = dnfLib.serviceUnits.postfix;
    expected = "postfix.service";
  };
  testServiceUnitNfsServer = {
    expr = dnfLib.serviceUnits.nfs;
    expected = "nfs-server.service";
  };

  # Regression: the unit is `kanidm`, the daemon binary `kanidmd`. The typo
  # produced no series, hence a `ServiceDown` rule that could never fire.
  testServiceUnitIdm = {
    expr = dnfLib.serviceUnits.idm;
    expected = "kanidm.service";
  };

  # Regression: watching `restic-rest-server.service` alerted on every boot and
  # on every automount idle-unmount, both of which leave the socket listening.
  testServiceUnitRestic = {
    expr = dnfLib.serviceUnits.restic;
    expected = "restic-rest-server.socket";
  };

  # Regression: watching `harmonia.service` alerted after every deploy, since
  # `switch-to-configuration` stops the service and restarts only the socket.
  testServiceUnitHarmonia = {
    expr = dnfLib.serviceUnits.harmonia;
    expected = "harmonia.socket";
  };

  # ----- nodeAlertEligible -----
  # Selection: infrastructure and must-stay-up hosts are watched; bare
  # laptops/desktops are not, unless an explicit feature opts them in.
  testEligibleServer = {
    expr = dnfLib.nodeAlertEligible { services = [ ]; } {
      hostname = "s";
      profile = "server";
      features = { };
      services = { };
    };
    expected = true;
  };
  testEligibleBareLaptop = {
    expr = dnfLib.nodeAlertEligible { services = [ ]; } {
      hostname = "l";
      profile = "laptop";
      features = { };
      services = { };
    };
    expected = false;
  };
  testEligibleLaptopWithService = {
    expr = dnfLib.nodeAlertEligible { services = [ ]; } {
      hostname = "l";
      profile = "laptop";
      features = { };
      services = {
        restic = { };
      };
    };
    expected = true;
  };
  testEligibleDisabled = {
    expr = dnfLib.nodeAlertEligible { services = [ ]; } {
      hostname = "s";
      profile = "server";
      features = {
        "alert-disabled" = "ag";
      };
      services = { };
    };
    expected = false;
  };
  testEligibleNonCriticalFeature = {
    expr = dnfLib.nodeAlertEligible { services = [ ]; } {
      hostname = "l";
      profile = "laptop";
      features = {
        "alert-non-critical" = "ag";
      };
      services = { };
    };
    expected = true;
  };

  # ----- reach label (mkNodeRuleGroups) -----
  # A same-zone host is `local`; a cross-zone host (reached over the WAN) is
  # `wan`, which lets ZoneInternetDown inhibit its false down-alert.
  testReachLocal = {
    expr =
      (builtins.head
        (builtins.head
          (dnfLib.mkNodeRuleGroups {
            nodes = [
              {
                hostname = "a";
                profile = "server";
                ip = "10.0.0.9";
                zone = "ag";
                features = { };
                services = { };
              }
            ];
            services = [ ];
            nodeExporterPort = 9100;
            zoneName = "ag";
          }).groups
        ).rules
      ).labels.reach;
    expected = "local";
  };
  testReachWan = {
    expr =
      (builtins.head
        (builtins.head
          (dnfLib.mkNodeRuleGroups {
            nodes = [
              {
                hostname = "hcs";
                profile = "hcs";
                ip = "1.2.3.4";
                zone = "www";
                features = { };
                services = { };
              }
            ];
            services = [ ];
            nodeExporterPort = 9100;
            zoneName = "ag";
          }).groups
        ).rules
      ).labels.reach;
    expected = "wan";
  };

  # ----- SystemdUnitFailed denylist (mkNodeRuleGroups) -----
  # Empty denylist (the default): the selector is left untouched, so every failed
  # unit still alerts.
  testSystemdFailedNoDenylist = {
    expr = (builtins.elemAt (nodeRules [ ]) 1).expr;
    expected = ''node_systemd_unit_state{instance="10.0.0.9:9100",state="failed"} == 1'';
  };

  # A denylisted unit is excluded by an anchored, regex-escaped `name!~` matcher:
  # `mautrix-telegram.service` is muted, `mautrix-telegramXservice` is not.
  testSystemdFailedDenylistEscaped = {
    expr = (builtins.elemAt (nodeRules [ "mautrix-telegram.service" ]) 1).expr;
    expected = ''node_systemd_unit_state{instance="10.0.0.9:9100",state="failed",name!~"mautrix-telegram\\.service"} == 1'';
  };

  # Several units share one alternation matcher.
  testSystemdFailedDenylistMultiple = {
    expr =
      (builtins.elemAt (nodeRules [
        "a.service"
        "b.timer"
      ]) 1).expr;
    expected = ''node_systemd_unit_state{instance="10.0.0.9:9100",state="failed",name!~"a\\.service|b\\.timer"} == 1'';
  };

  # The denylist must not leak into the other node rules (NodeDown here).
  testSystemdDenylistDoesNotTouchNodeDown = {
    expr = (builtins.head (nodeRules [ "mautrix-telegram.service" ])).expr;
    expected = ''up{job="node",instance="10.0.0.9:9100"} == 0'';
  };

  # ----- ServiceDown per-unit label -----
  # A host running several watched services yields one ServiceDown rule per unit,
  # each tagged with a distinct `unit` label. Without it the rules would share the
  # same name+labels signature (Alertmanager collision + promtool duplicate lint).
  testServiceDownUnitLabels = {
    expr = map (r: r.labels.unit) (
      builtins.filter (r: (r.alert or "") == "ServiceDown") (
        (builtins.head
          (dnfLib.mkNodeRuleGroups {
            nodes = [
              {
                hostname = "a";
                profile = "server";
                ip = "10.0.0.9";
                zone = "ag";
                features = { };
                services = {
                  forgejo = { };
                  headscale = { };
                };
              }
            ];
            services = [ ];
            nodeExporterPort = 9100;
            zoneName = "ag";
          }).groups
        ).rules
      )
    );
    expected = [
      "forgejo.service"
      "headscale.service"
    ];
  };

  # ----- mkNetworkRuleGroups (zone label + custom expr) -----
  testNetworkZoneLabel = {
    expr =
      (builtins.head
        (builtins.head
          (dnfLib.mkNetworkRuleGroups {
            zoneName = "ag";
            probes = [
              {
                name = "gw";
                instance = "100.64.0.1";
                job = "blackbox-icmp";
                severity = "critical";
              }
            ];
          }).groups
        ).rules
      ).labels.zone;
    expected = "ag";
  };
  testNetworkInternetExpr = {
    expr =
      (builtins.head
        (builtins.head
          (dnfLib.mkNetworkRuleGroups {
            zoneName = "ag";
            probes = [
              {
                alert = "ZoneInternetDown";
                name = "internet ag";
                job = "blackbox-internet";
                severity = "critical";
                expr = ''min by (job) (probe_success{job="blackbox-internet"}) == 0'';
              }
            ];
          }).groups
        ).rules
      ).expr;
    expected = ''min by (job) (probe_success{job="blackbox-internet"}) == 0'';
  };

  # ----- mkHttpRuleGroups -----
  # Three rules per endpoint: liveness + two cert-expiry thresholds.
  testHttpRuleCount = {
    expr =
      builtins.length
        (builtins.head
          (dnfLib.mkHttpRuleGroups {
            zoneName = "ag";
            probes = [
              {
                name = "git";
                instance = "https://git.ag";
              }
            ];
          }).groups
        ).rules;
    expected = 3;
  };
  testHttpEndpointExpr = {
    expr =
      (builtins.head
        (builtins.head
          (dnfLib.mkHttpRuleGroups {
            zoneName = "ag";
            probes = [
              {
                name = "git";
                instance = "https://git.ag";
              }
            ];
          }).groups
        ).rules
      ).expr;
    expected = ''probe_success{job="blackbox-http",instance="https://git.ag"} == 0'';
  };

  # ----- mkResticRuleGroups -----
  # `backup` in the `by (...)` clause: one alert per job, a failing one is never
  # masked by a sibling. `host` too: an aggregation drops every ungrouped label.
  testResticStaleExpr = {
    expr =
      (builtins.head (builtins.head (dnfLib.mkResticRuleGroups { zoneName = "ag"; }).groups).rules).expr;
    expected = "time() - max by (instance, backup, host) (dnf_restic_last_success_timestamp) > 129600";
  };
  testResticCriticalExpr = {
    expr =
      (builtins.elemAt (builtins.head (dnfLib.mkResticRuleGroups { zoneName = "ag"; }).groups).rules 1)
      .expr;
    expected = "time() - max by (instance, backup, host) (dnf_restic_last_success_timestamp) > 604800";
  };

  # ----- mkSmartctlRuleGroups -----
  testSmartctlFailingExpr = {
    expr =
      (builtins.head (builtins.head (dnfLib.mkSmartctlRuleGroups { zoneName = "ag"; }).groups).rules)
      .expr;
    expected = "smartctl_device_smart_status == 0";
  };

  # ----- mkPostfixRuleGroups -----
  testPostfixUpExpr = {
    expr =
      (builtins.head (builtins.head (dnfLib.mkPostfixRuleGroups { zoneName = "ag"; }).groups).rules).expr;
    expected = "postfix_up == 0";
  };

  # ----- mkSynapseRuleGroups -----
  testSynapseRestartExpr = {
    expr =
      (builtins.head (builtins.head (dnfLib.mkSynapseRuleGroups { zoneName = "ag"; }).groups).rules).expr;
    expected = ''changes(process_start_time_seconds{job="synapse"}[30m]) > 2'';
  };

  # ----- mkTailscaleRuleGroups -----
  testTailscaleFlappingExpr = {
    expr =
      (builtins.head (builtins.head (dnfLib.mkTailscaleRuleGroups { zoneName = "ag"; }).groups).rules)
      .expr;
    expected = "increase(dnf_tailscale_selfheal_restarts_total[1h]) > 3";
  };
  testTailscaleGroupName = {
    expr = (builtins.head (dnfLib.mkTailscaleRuleGroups { zoneName = "ag"; }).groups).name;
    expected = "dnf-tailscale-ag";
  };

  # ----- mkHeadscaleRuleGroups -----
  testHeadscaleGroupName = {
    expr = (builtins.head (dnfLib.mkHeadscaleRuleGroups { zoneName = "ag"; }).groups).name;
    expected = "dnf-headscale-ag";
  };
  testHeadscaleAlertNames = {
    expr =
      map (r: r.alert)
        (builtins.head (dnfLib.mkHeadscaleRuleGroups { zoneName = "ag"; }).groups).rules;
    expected = [
      "HeadscaleNodeDrift"
      "HeadscaleUnexpectedNode"
      "HeadscalePolicyInvalid"
      "HeadscaleOidcFallback"
      "HeadscaleNodeExpiring"
      "HeadscaleAuditStale"
    ];
  };

  # One alert covers the three per-node checks: the regex must name them all.
  testHeadscaleDriftExpr = {
    expr =
      (builtins.head (builtins.head (dnfLib.mkHeadscaleRuleGroups { zoneName = "ag"; }).groups).rules)
      .expr;
    expected = ''max by (instance, host, node) ({__name__=~"dnf_headscale_node_(missing|tag_mismatch|ip_drift)"}) == 1'';
  };
  testHeadscaleExpiringExpr = {
    expr =
      (builtins.elemAt (builtins.head (dnfLib.mkHeadscaleRuleGroups { zoneName = "ag"; }).groups).rules 4)
      .expr;
    expected = "dnf_headscale_node_expiry_timestamp_seconds - time() < 604800";
  };

  # Metric-driven like restic and tailscale: always part of the zone document.
  testRuleGroupsIncludeHeadscale = {
    expr =
      (builtins.elemAt
        (dnfLib.mkAlertRuleGroups {
          nodes = [ critServer ];
          services = [ ];
          nodeExporterPort = 9100;
          zoneName = "ag";
        }).groups
        5
      ).name;
    expected = "dnf-headscale-ag";
  };

  # ----- host label -----
  # Node rules carry the hostname under `host`, the label the Matrix bot renders
  # on the title line ("<alert> at srv-main") instead of the raw `<ip>:<port>`.
  testNodeRuleHostLabel = {
    expr = (builtins.head (nodeRules [ ])).labels.host;
    expected = "a";
  };

  # Generic (zone-wide) rules cannot know the hostname at eval time: they get
  # `host` from the scrape target. The instance therefore has to travel in the
  # description, which is the only annotation the bot renders.
  testResourceDescriptionCarriesInstance = {
    expr =
      (builtins.head
        (builtins.head
          (dnfLib.mkResourceRuleGroups {
            zoneName = "ag";
            thresholds = { };
          }).groups
        ).rules
      ).annotations.description;
    expected = "{{ $labels.device }} below 15% free on {{ $labels.instance }}. ${mountsSentence}";
  };

  testSynapseErrorRateGroupsHost = {
    expr =
      (builtins.elemAt (builtins.head (dnfLib.mkSynapseRuleGroups { zoneName = "ag"; }).groups).rules 1)
      .expr;
    expected = ''sum by (instance, host) (rate(synapse_http_server_responses_total{job="synapse",code=~"5.."}[15m])) / sum by (instance, host) (rate(synapse_http_server_responses_total{job="synapse"}[15m])) > 0.05'';
  };

  # ----- mkResourceRuleGroups (filesystem selectors) -----

  # A mount that is read-only by design (optical media) would alert forever:
  # `FilesystemReadOnly` excludes those fstypes on top of the shared selector.
  testFilesystemReadOnlyExcludesByDesignFstypes = {
    expr = (resourceRule { } "FilesystemReadOnly").expr;
    expected =
      perDev "max" ''node_filesystem_readonly{${fsSel},fstype!~"iso9660|udf|erofs"}'' + " == 1";
  };

  # Remote mounts leave every filesystem rule, not just the read-only one: their
  # space is the exporting server's, and it is scraped there.
  testDiskSpaceLowExcludesRemoteMounts = {
    expr = (resourceRule { } "DiskSpaceLow").expr;
    expected =
      perDev "min" "100 * node_filesystem_avail_bytes{${fsSel}} / node_filesystem_size_bytes{${fsSel}}"
      + " < 15";
  };

  # Emptying the list puts network shares back under watch, for a NAS that runs
  # no node-exporter of its own.
  testRemoteFstypesOverride = {
    expr = (resourceRule { remoteFstypes = [ ]; } "InodesLow").expr;
    expected =
      let
        sel = ''fstype!~"tmpfs|ramfs|overlay|squashfs|fuse.*",mountpoint!~"/(boot|nix/store).*"'';
      in
      perDev "min" "100 * node_filesystem_files_free{${sel}} / node_filesystem_files{${sel}}" + " < 10";
  };

  # An empty override disarms the exclusion without leaving a dangling, empty
  # fstype matcher behind.
  testFilesystemReadOnlyEmptyExclusion = {
    expr = (resourceRule { readOnlyByDesignFstypes = [ ]; } "FilesystemReadOnly").expr;
    expected = perDev "max" "node_filesystem_readonly{${fsSel}}" + " == 1";
  };

  # Overrides replace the default list (attrset merge), they do not append to it.
  testFilesystemReadOnlyCustomExclusion = {
    expr = (resourceRule { readOnlyByDesignFstypes = [ "vfat" ]; } "FilesystemReadOnly").expr;
    expected = perDev "max" ''node_filesystem_readonly{${fsSel},fstype!~"vfat"}'' + " == 1";
  };

  # ----- mkResourceRuleGroups (one alert per partition) -----

  # A btrfs holding `/`, `/nix`, `/home` and `/.swapfile` exports four
  # identical series: unaggregated, one full disk pages four times.
  testDiskSpaceCriticalAggregatesPerDevice = {
    expr = (resourceRule { } "DiskSpaceCritical").expr;
    expected =
      perDev "min" "100 * node_filesystem_avail_bytes{${fsSel}} / node_filesystem_size_bytes{${fsSel}}"
      + " < 5";
  };

  # Both sides of the `and` are aggregated: an unaggregated side still carries
  # `mountpoint` and matches nothing against the aggregated one.
  testDiskWillFillSoonAggregatesBothSides = {
    expr = (resourceRule { } "DiskWillFillSoon").expr;
    expected =
      perDev "min" "predict_linear(node_filesystem_avail_bytes{${fsSel}}[6h], 24*3600)"
      + " < 0 and "
      + perDev "min" "node_filesystem_avail_bytes{${fsSel}} / node_filesystem_size_bytes{${fsSel}}"
      + " < 0.4";
  };

  # `mountpoint` is gone from filesystem alerts: the description names the
  # partition, then the mounts it carries.
  testInodesLowDescriptionNamesDeviceAndMounts = {
    expr = (resourceRule { } "InodesLow").annotations.description;
    expected = "{{ $labels.device }} below 10% free inodes on {{ $labels.instance }}. ${mountsSentence}";
  };

  # ----- mkSilenceRoutes -----
  testSilenceRoutesEmpty = {
    expr = dnfLib.mkSilenceRoutes [ ];
    expected = [ ];
  };

  # Minimal entry: only `alertname` is constrained, so the alert is muted on
  # every host and every label combination.
  testSilenceRouteMinimal = {
    expr = dnfLib.mkSilenceRoutes [
      {
        alert = "DiskSpaceLow";
        reason = "documented elsewhere";
      }
    ];
    expected = [
      {
        matchers = [ ''alertname="DiskSpaceLow"'' ];
        receiver = "null";
      }
    ];
  };

  # Full entry: alertname first, then host, then the extra matchers sorted by
  # label name (attrset iteration order). All ANDed by Alertmanager.
  testSilenceRouteFull = {
    expr = dnfLib.mkSilenceRoutes [
      {
        alert = "DiskSpaceLow";
        host = "srv-main";
        matchers = {
          mountpoint = "/mnt/backup";
          device = "/dev/sdb";
        };
        reason = "backup disk intentionally near full";
      }
    ];
    expected = [
      {
        matchers = [
          ''alertname="DiskSpaceLow"''
          ''host="srv-main"''
          ''device="/dev/sdb"''
          ''mountpoint="/mnt/backup"''
        ];
        receiver = "null";
      }
    ];
  };

  # A null (or empty) host yields no `host` matcher: the silence stays fleet-wide
  # instead of accidentally matching a host literally named "null".
  testSilenceRouteNullHost = {
    expr =
      (builtins.head (
        dnfLib.mkSilenceRoutes [
          {
            alert = "ClockSkew";
            host = null;
            reason = "r";
          }
        ]
      )).matchers;
    expected = [ ''alertname="ClockSkew"'' ];
  };
  testSilenceRouteEmptyHost = {
    expr =
      (builtins.head (
        dnfLib.mkSilenceRoutes [
          {
            alert = "ClockSkew";
            host = "";
            reason = "r";
          }
        ]
      )).matchers;
    expected = [ ''alertname="ClockSkew"'' ];
  };

  # Values are interpolated into a quoted matcher string, so `"` and `\` must be
  # escaped or the emitted Alertmanager config would not parse.
  testSilenceRouteEscaping = {
    expr =
      (builtins.head (
        dnfLib.mkSilenceRoutes [
          {
            alert = "SystemdUnitFailed";
            matchers.name = ''a"b\c'';
            reason = "r";
          }
        ]
      )).matchers;
    expected = [
      ''alertname="SystemdUnitFailed"''
      ''name="a\"b\\c"''
    ];
  };

  # Several silences yield one independent route each.
  testSilenceRoutesMultiple = {
    expr = builtins.length (
      dnfLib.mkSilenceRoutes [
        {
          alert = "DiskSpaceLow";
          host = "srv-main";
          reason = "r";
        }
        {
          alert = "ClockSkew";
          host = "gw";
          reason = "r";
        }
      ]
    );
    expected = 2;
  };
}
