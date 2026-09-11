# Tests for dnf/lib/headscale-policy.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  network = {
    coordination = {
      enable = true;
      hostname = "hcs";
    };
    zones = {
      www = {
        name = "www";
        gateway.hostname = "hcs";
      };
      lan = {
        name = "lan";
        networkIp = "10.1.0.0";
        prefixLength = 16;
        gateway = {
          hostname = "gw-lan";
          lan.ip = "10.1.1.1";
        };
      };
      far = {
        name = "far";
        networkIp = "10.2.0.0";
        prefixLength = 16;
        gateway = {
          hostname = "gw-far";
          lan.ip = "10.2.1.1";
        };
      };
    };
  };

  hcs = {
    hostname = "hcs";
    zone = "www";
    ip = "203.0.113.1";
    vpnIp = "100.64.0.2";
    groups = [ ];
  };
  gwLan = {
    hostname = "gw-lan";
    zone = "lan";
    ip = "10.1.1.1";
    groups = [ ];
  };
  gwFar = {
    hostname = "gw-far";
    zone = "far";
    ip = "10.2.1.1";
    groups = [ ];
  };
  laptop = {
    hostname = "laptop";
    zone = "lan";
    ip = "10.1.12.1";
    groups = [ "admin" ];
  };
  desktop = {
    hostname = "desktop";
    zone = "lan";
    ip = "10.1.11.1";
    groups = [ "zone-lan" ];
  };
  hosts = [
    hcs
    gwLan
    gwFar
    laptop
    desktop
  ];

  users = {
    alice = {
      profile = "dnf/home/profiles/admin";
      groups = [ "zone-lan" ];
    };
    bob = {
      profile = "dnf/home/profiles/normal";
      groups = [
        "zone-far"
        "global"
      ];
    };
    guest = {
      profile = "dnf/home/profiles/normal";
      groups = [ "guests" ];
    };
  };

  policy = args: dnfLib.mkHeadscalePolicy ({ inherit network hosts users; } // args);
  enforced = policy { };
  hasRule = acls: rule: builtins.elem rule acls;
  lastRule = acls: builtins.elemAt acls (builtins.length acls - 1);
  allTargets = [
    "tag:hcs"
    "tag:gw-far"
    "tag:gw-lan"
    "tag:admin"
    "zone-far"
    "zone-lan"
  ];
in
{

  # ----- tailnetNodeTags -----
  testTagsHcs = {
    expr = dnfLib.tailnetNodeTags {
      host = hcs;
      inherit network;
    };
    expected = [ "tag:hcs" ];
  };
  testTagsGateway = {
    expr = dnfLib.tailnetNodeTags {
      host = gwLan;
      inherit network;
    };
    expected = [ "tag:gw-lan" ];
  };
  testTagsAdminStation = {
    expr = dnfLib.tailnetNodeTags {
      host = laptop;
      inherit network;
    };
    expected = [ "tag:admin" ];
  };
  testTagsPlainHost = {
    expr = dnfLib.tailnetNodeTags {
      host = desktop;
      inherit network;
    };
    expected = [ ];
  };

  # Admins logging in on a gateway do not make it an admin station.
  testTagsGatewayWithAdminGroup = {
    expr = dnfLib.tailnetNodeTags {
      host = gwFar // {
        groups = [ "admin" ];
      };
      inherit network;
    };
    expected = [ "tag:gw-far" ];
  };
  testHostsSkipGatewayWithAdminGroup = {
    expr = (policy { hosts = [ (gwFar // { groups = [ "admin" ]; }) ]; }).hosts ? gw-far;
    expected = false;
  };

  # The global zone gateway name must not yield a `tag:gw-www`.
  testTagsGlobalGatewayName = {
    expr = dnfLib.tailnetNodeTags {
      host = hcs // {
        vpnIp = "";
      };
      inherit network;
    };
    expected = [ "tag:hcs" ];
  };

  # ----- tailnetUsers -----
  testTailnetUsers = {
    expr = dnfLib.tailnetUsers users;
    expected = [
      "alice"
      "bob"
    ];
  };

  # ----- mkHeadscalePolicy: identities -----
  testHosts = {
    expr = enforced.hosts;
    expected = {
      zone-far = "10.2.0.0/16";
      zone-lan = "10.1.0.0/16";
      gateway-far = "10.2.1.1/32";
      gateway-lan = "10.1.1.1/32";
      laptop = "10.1.12.1/32";
    };
  };
  testAdminDeviceAlias = {
    expr = (policy { adminDevices.phone = "100.64.0.9"; }).hosts.phone;
    expected = "100.64.0.9/32";
  };
  testGroups = {
    expr = enforced.groups;
    expected = {
      "group:admins" = [ "alice@" ];
      "group:zone-far" = [ "bob@" ];
      "group:zone-lan" = [ "alice@" ];
    };
  };
  testTagOwners = {
    expr = enforced.tagOwners;
    expected = {
      "tag:admin" = [ "group:admins" ];
      "tag:gw-far" = [ "group:admins" ];
      "tag:gw-lan" = [ "group:admins" ];
      "tag:hcs" = [ "group:admins" ];
    };
  };

  # No admin user: owners stay empty instead of naming an undefined group.
  testTagOwnersWithoutAdmins = {
    expr = (policy { users = { inherit (users) bob; }; }).tagOwners."tag:hcs";
    expected = [ ];
  };
  testAutoApprovers = {
    expr = enforced.autoApprovers;
    expected = {
      routes = {
        "10.1.0.0/16" = [ "tag:gw-lan" ];
        "10.2.0.0/16" = [ "tag:gw-far" ];
      };
      exitNode = [ "tag:hcs" ];
    };
  };

  # ----- mkHeadscalePolicy: enforced rules -----
  testInfraRule = {
    expr = builtins.head enforced.acls;
    expected = {
      action = "accept";
      src = allTargets;
      dst = map (t: "${t}:*") allTargets;
    };
  };
  testPersonalHcsRule = {
    expr = hasRule enforced.acls {
      action = "accept";
      src = [ "autogroup:member" ];
      dst = [ "tag:hcs:53,443" ];
    };
    expected = true;
  };
  testAdminUsersReachEveryZone = {
    expr = hasRule enforced.acls {
      action = "accept";
      src = [ "group:admins" ];
      dst = [
        "tag:gw-far:443"
        "gateway-far:443"
        "tag:gw-lan:443"
        "gateway-lan:443"
      ];
    };
    expected = true;
  };
  testZoneUsersReachOwnZone = {
    expr = hasRule enforced.acls {
      action = "accept";
      src = [ "group:zone-far" ];
      dst = [
        "tag:gw-far:443"
        "gateway-far:443"
      ];
    };
    expected = true;
  };

  # A gateway without a LAN address is reached on its tailnet IPs only.
  testGatewayWithoutLanIp =
    let
      noLanIp = policy {
        network = network // {
          zones = network.zones // {
            far = network.zones.far // {
              gateway.hostname = "gw-far";
            };
          };
        };
      };
    in
    {
      expr = {
        alias = noLanIp.hosts ? gateway-far;
        rule = hasRule noLanIp.acls {
          action = "accept";
          src = [ "group:zone-far" ];
          dst = [ "tag:gw-far:443" ];
        };
      };
      expected = {
        alias = false;
        rule = true;
      };
    };
  testSelfRule = {
    expr = hasRule enforced.acls {
      action = "accept";
      src = [ "autogroup:member" ];
      dst = [ "autogroup:self:*" ];
    };
    expected = true;
  };
  testSshFromStationsAndDevices = {
    expr = hasRule (policy { adminDevices.phone = "100.64.0.9"; }).acls {
      action = "accept";
      src = [
        "tag:admin"
        "laptop"
        "phone"
      ];
      dst = map (t: "${t}:22") allTargets;
    };
    expected = true;
  };
  testNoExitRuleByDefault = {
    expr = builtins.any (r: builtins.elem "autogroup:internet:*" r.dst) enforced.acls;
    expected = false;
  };
  testExitRule = {
    expr = lastRule (policy { exitNodeSources = [ "group:admins" ]; }).acls;
    expected = {
      action = "accept";
      src = [ "group:admins" ];
      dst = [ "autogroup:internet:*" ];
    };
  };
  testExtraAclsLast =
    let
      extra = {
        action = "accept";
        src = [ "zone-lan" ];
        dst = [ "tag:hcs:25" ];
      };
    in
    {
      expr = lastRule (policy { extraAcls = [ extra ]; }).acls;
      expected = extra;
    };

  # ----- mkHeadscalePolicy: open mode -----
  testOpenModeNamesZones = {
    expr = (policy { enforce = false; }).acls;
    expected = [
      {
        action = "accept";
        src = [
          "*"
          "zone-far"
          "zone-lan"
        ];
        dst = [
          "*:*"
          "zone-far:*"
          "zone-lan:*"
          "autogroup:internet:*"
        ];
      }
    ];
  };
  testOpenModeKeepsIdentities = {
    expr = (policy { enforce = false; }).autoApprovers == enforced.autoApprovers;
    expected = true;
  };
}
