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
  # Two groups (nodes + resources); the disabled laptop is dropped, leaving a
  # single watched node with the node-down + systemd-failed rules.
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
    expected = 2;
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
}
