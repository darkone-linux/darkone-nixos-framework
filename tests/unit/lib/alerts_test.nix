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
  # Five groups (nodes + resources + restic + smartctl + tailscale); the disabled
  # laptop is dropped, leaving a single watched node with node-down +
  # systemd-failed rules.
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
    expected = 5;
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
    expected = ''node_systemd_unit_state{instance="10.0.0.9:9100",state="failed",name!~"mautrix-telegram\.service"} == 1'';
  };

  # Several units share one alternation matcher.
  testSystemdFailedDenylistMultiple = {
    expr =
      (builtins.elemAt (nodeRules [
        "a.service"
        "b.timer"
      ]) 1).expr;
    expected = ''node_systemd_unit_state{instance="10.0.0.9:9100",state="failed",name!~"a\.service|b\.timer"} == 1'';
  };

  # The denylist must not leak into the other node rules (NodeDown here).
  testSystemdDenylistDoesNotTouchNodeDown = {
    expr = (builtins.head (nodeRules [ "mautrix-telegram.service" ])).expr;
    expected = ''up{job="node",instance="10.0.0.9:9100"} == 0'';
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
  testResticStaleExpr = {
    expr =
      (builtins.head (builtins.head (dnfLib.mkResticRuleGroups { zoneName = "ag"; }).groups).rules).expr;
    expected = "time() - max by (instance, job) (dnf_restic_last_success_timestamp) > 129600";
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
}
