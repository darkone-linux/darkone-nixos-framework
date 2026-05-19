# Mock specialArgs for DNF L2 simulation tests.
#
# Provides minimal but structurally complete stubs for the specialArgs
# that dnf/lib/hive.nix::mkNodeArgs injects into every NixOS host:
# host, zone, network, hosts, users, userNixosProfiles, workDir, dnfLib.
#
# Shape notes:
# - network.services must be a LIST (lib.findFirst used by several modules)
# - zone.name must match the key used in network.zones (supertuxkart option default)
# - host.services must be an attrset (gateway.nix option defaults use builtins.hasAttr)

{ pkgs, dnfLib }:
let

  mockZone = {
    # name is the zone key from network.zones (referenced by supertuxkart.nix options)
    name = "sim";
    domain = "sim.local";
    networkIp = "10.99.0.0";
    prefixLength = 24;
    gateway = {
      wan = {
        interface = "eth0";
        ip = "192.168.1.1";
      };
      lan = {
        interfaces = [ "eth1" ];
        ip = "10.99.0.1";
      };
      vpn = {
        ipv4 = "100.64.0.1";
      };
    };
    extraHosts = [ ];
    extraDnsmasqSettings = { };
  };

  mockHost = {
    hostname = "sim-host";
    name = "Sim Host";
    profile = "minimal";
    users = [ ];
    groups = [ ];
    arch = "x86_64-linux";

    # Empty services map — gateway.nix checks `builtins.hasAttr "adguardhome" host.services`
    # in option defaults so this must be an attrset.
    services = { };

    zone = "sim";
    zoneDomain = "sim.local";
  };

  mockNetwork = {
    domain = "sim.local";
    coordination = {
      enable = false;
      hostname = "sim-hcs";
      domain = "sim.local";
    };

    # zones must contain the key referenced by mockHost.zone
    zones = {
      sim = mockZone;
    };

    # services is a list of service descriptors — modules use lib.findFirst on it.
    # Must be a list, NOT an attrset (supertuxkart, ncps use lib.findFirst).
    services = [ ];

    smtp = {
      protocol = "smtp";
      server = "localhost";
      port = 25;
      username = "test";
      tls = false;
    };
  };

in
{
  inherit
    mockHost
    mockZone
    mockNetwork
    dnfLib
    ;

  # zone specialArg = network.zones.${host.zone} (see dnf/lib/hive.nix)
  mockZoneArg = mockZone;

  mockHosts = [ mockHost ];
  mockUsers = { };
  mockUserNixosProfiles = { };

  # Placeholder — never accessed in tests where core is disabled or standalone = true.
  mockWorkDir = "/nonexistent-test-workdir";

  # Complete specialArgs attrset ready for injection as node.specialArgs.
  # Factored here so simulate/default.nix::mkTest can inject them uniformly
  # without repeating the full list in every scenario file.
  mockSpecialArgs = {
    host = mockHost;
    zone = mockZone;
    network = mockNetwork;
    hosts = [ mockHost ];
    users = { };
    userNixosProfiles = { };
    workDir = "/nonexistent-test-workdir";
    inherit dnfLib;
    "pkgs-stable" = pkgs;
  };
}
