# Tests for dnf/lib/topology.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  inherit (dnfLib) constants;

  mockHost = {
    hostname = "testhost";
    zone = "lan";
    networkDomain = "example.com";
    zoneDomain = "lan.example.com";
    ip = "192.168.1.10";
  };

  mockZone = {
    name = "lan";
    gateway.hostname = "testhost";
  };

  mockGlobalZone = {
    name = constants.globalZone;
    gateway.hostname = "hcshost";
  };

  hcsHost = {
    hostname = "hcshost";
    zone = constants.globalZone;
    networkDomain = "example.com";
    zoneDomain = "example.com";
    ip = "203.0.113.1";
  };

  mockNetworkHcs = {
    coordination = {
      enable = true;
      hostname = "hcshost";
    };
    services = [ ];
  };

  mockHosts = [
    mockHost
    (
      mockHost
      // {
        hostname = "otherhost";
        zone = "dmz";
      }
    )
    hcsHost
  ];

  # NFS fixtures: one server in `lan`, one client tagged with the server's zone.
  nfsSrvHost = {
    hostname = "nfssrv";
    zone = "lan";
  };
  nfsClientHost = {
    hostname = "nfsclient";
    zone = "lan";
    ip = "192.168.1.20";
    features.nfs-client = "lan";
  };
  nfsHosts = [
    nfsSrvHost
    nfsClientHost
    mockHost
  ];
  nfsServices = [
    {
      name = "nfs";
      host = "nfssrv";
      zone = "lan";
    }
  ];

  mockServices = [
    {
      name = "wiki";
      host = "testhost";
      zone = "lan";
    }
    {
      name = "wiki";
      host = "otherhost";
      zone = "dmz";
    }
    {
      name = "global-svc";
      host = "hcshost";
      zone = constants.globalZone;
      global = true;
    }
  ];
in
{

  # ----- isVpnClient -----
  testIsVpnClientTrue = {
    expr = dnfLib.isVpnClient { vpnIp = "100.64.1.1"; };
    expected = true;
  };
  testIsVpnClientFalseMissing = {
    expr = dnfLib.isVpnClient { hostname = "testhost"; };
    expected = false;
  };
  testIsVpnClientFalseEmpty = {
    expr = dnfLib.isVpnClient { vpnIp = ""; };
    expected = false;
  };

  # ----- inLocalZone -----
  testInLocalZoneTrue = {
    expr = dnfLib.inLocalZone { name = "lan"; };
    expected = true;
  };
  testInLocalZoneFalse = {
    expr = dnfLib.inLocalZone { name = constants.globalZone; };
    expected = false;
  };

  # ----- isGateway -----
  testIsGatewayTrue = {
    expr = dnfLib.isGateway mockHost mockZone;
    expected = true;
  };
  testIsGatewayFalseNotGateway = {
    expr = dnfLib.isGateway (mockHost // { hostname = "otherhost"; }) mockZone;
    expected = false;
  };
  testIsGatewayFalseVpnClient = {
    expr = dnfLib.isGateway (mockHost // { vpnIp = "100.64.1.1"; }) mockZone;
    expected = false;
  };

  # ----- isHcs -----
  testIsHcsTrue = {
    expr = dnfLib.isHcs hcsHost mockGlobalZone mockNetworkHcs;
    expected = true;
  };
  testIsHcsFalseLocalZone = {
    expr = dnfLib.isHcs hcsHost mockZone mockNetworkHcs;
    expected = false;
  };
  testIsHcsFalseNoCoordination = {
    expr = dnfLib.isHcs hcsHost mockGlobalZone (mockNetworkHcs // { coordination.enable = false; });
    expected = false;
  };

  # ----- findHost -----
  testFindHostFound = {
    expr = (dnfLib.findHost "testhost" "lan" mockHosts).hostname;
    expected = "testhost";
  };
  testFindHostMissing = {
    expr = dnfLib.findHost "ghost" "lan" mockHosts;
    expected = { };
  };

  # ----- findService -----
  testFindServiceFound = {
    expr = (dnfLib.findService "wiki" "lan" mockServices).host;
    expected = "testhost";
  };
  testFindServiceMissing = {
    expr = dnfLib.findService "ghost" "lan" mockServices;
    expected = null;
  };

  # ----- preferredIp -----
  testPreferredIpVpn = {
    expr = dnfLib.preferredIp {
      vpnIp = "100.64.1.5";
      ip = "192.168.1.10";
    };
    expected = "100.64.1.5";
  };
  testPreferredIpFallbackLan = {
    expr = dnfLib.preferredIp {
      vpnIp = "";
      ip = "192.168.1.10";
    };
    expected = "192.168.1.10";
  };
  testPreferredIpNoVpnAttr = {
    expr = dnfLib.preferredIp { ip = "10.0.0.5"; };
    expected = "10.0.0.5";
  };
  testPreferredIpLoopback = {
    expr = dnfLib.preferredIp { };
    expected = "127.0.0.1";
  };

  # ----- resolveNfs -----
  testResolveNfsServer = {
    expr = dnfLib.resolveNfs {
      host = nfsSrvHost;
      hosts = nfsHosts;
      zone = mockZone;
      services = nfsServices;
    };
    expected = {
      count = 1;
      server = "nfssrv";
      hasServer = true;
      isServer = true;
      isClient = false;
      clientIps = [ "192.168.1.20" ];
    };
  };
  testResolveNfsClient = {
    expr =
      (dnfLib.resolveNfs {
        host = nfsClientHost;
        hosts = nfsHosts;
        zone = mockZone;
        services = nfsServices;
      }).isClient;
    expected = true;
  };

  # The feature must point at the server's own zone: cross-zone clients are not
  # wired yet, and one of the former copies silently accepted them.
  testResolveNfsClientWrongZone = {
    expr =
      (dnfLib.resolveNfs {
        host = nfsClientHost // {
          features.nfs-client = "dmz";
        };
        hosts = nfsHosts;
        zone = mockZone;
        services = nfsServices;
      }).isClient;
    expected = false;
  };
  testResolveNfsNoFeature = {
    expr =
      (dnfLib.resolveNfs {
        host = nfsClientHost // {
          features = { };
        };
        hosts = nfsHosts;
        zone = mockZone;
        services = nfsServices;
      }).isClient;
    expected = false;
  };

  # `features` absent altogether must not abort (hosts declare it optionally).
  testResolveNfsMissingFeaturesAttr = {
    expr =
      (dnfLib.resolveNfs {
        host = mockHost;
        hosts = nfsHosts;
        zone = mockZone;
        services = nfsServices;
      }).isClient;
    expected = false;
  };

  # No `nfs` service in the zone: used to abort with `attempt to select
  # attribute 'host' on null` instead of degrading.
  testResolveNfsNoServer = {
    expr = dnfLib.resolveNfs {
      host = nfsClientHost;
      hosts = nfsHosts;
      zone = mockZone;
      services = [ ];
    };
    expected = {
      count = 0;
      server = null;
      hasServer = false;
      isServer = false;
      isClient = false;
      clientIps = [ ];
    };
  };

  # `clientIps` feeds /etc/exports: a host without the feature, the server
  # itself and a cross-zone client must all stay out of it.
  testResolveNfsClientIpsExcludesNonClients = {
    expr =
      (dnfLib.resolveNfs {
        host = nfsSrvHost;
        hosts = nfsHosts ++ [
          {
            hostname = "crosszone";
            zone = "lan";
            ip = "192.168.1.30";
            features.nfs-client = "dmz";
          }
        ];
        zone = mockZone;
        services = nfsServices;
      }).clientIps;
    expected = [ "192.168.1.20" ];
  };

  # A client declared without an address would export to the empty string,
  # which `exportfs` reads as "everyone".
  testResolveNfsClientIpsDropsAddressless = {
    expr =
      (dnfLib.resolveNfs {
        host = nfsSrvHost;
        hosts = [
          nfsSrvHost
          {
            hostname = "noaddr";
            zone = "lan";
            features.nfs-client = "lan";
          }
        ];
        zone = mockZone;
        services = nfsServices;
      }).clientIps;
    expected = [ ];
  };

  # Two servers in one zone: `count` lets the caller assert the invariant.
  testResolveNfsTwoServers = {
    expr =
      (dnfLib.resolveNfs {
        host = nfsClientHost;
        hosts = nfsHosts;
        zone = mockZone;
        services = nfsServices ++ [
          {
            name = "nfs";
            host = "otherhost";
            zone = "lan";
          }
        ];
      }).count;
    expected = 2;
  };

  # ----- resolveZoneService -----

  # `serverHost` is the resolved host attrset, needed to address the share.
  testResolveZoneServiceServer = {
    expr = dnfLib.resolveZoneService {
      name = "stk";
      host = nfsSrvHost;
      hosts = nfsHosts;
      zone = mockZone;
      services = [
        {
          name = "stk";
          host = "nfssrv";
          zone = "lan";
        }
      ];
    };
    expected = {
      count = 1;
      server = "nfssrv";
      serverHost = nfsSrvHost;
      hasServer = true;
      isServer = true;
    };
  };

  # Seen from a non-server host of the same zone.
  testResolveZoneServiceOtherHost = {
    expr =
      (dnfLib.resolveZoneService {
        name = "stk";
        host = nfsClientHost;
        hosts = nfsHosts;
        zone = mockZone;
        services = [
          {
            name = "stk";
            host = "nfssrv";
            zone = "lan";
          }
        ];
      }).isServer;
    expected = false;
  };

  # A server declared in another zone must not leak into this one.
  testResolveZoneServiceOtherZone = {
    expr = dnfLib.resolveZoneService {
      name = "stk";
      host = nfsClientHost;
      hosts = nfsHosts;
      zone = mockZone;
      services = [
        {
          name = "stk";
          host = "nfssrv";
          zone = "dmz";
        }
      ];
    };
    expected = {
      count = 0;
      server = null;
      serverHost = { };
      hasServer = false;
      isServer = false;
    };
  };

  # Another service of the same zone must not answer for `stk`.
  testResolveZoneServiceOtherName = {
    expr =
      (dnfLib.resolveZoneService {
        name = "stk";
        host = nfsClientHost;
        hosts = nfsHosts;
        zone = mockZone;
        services = nfsServices;
      }).hasServer;
    expected = false;
  };

  # Two servers in one zone: `count` lets the caller assert the invariant.
  testResolveZoneServiceTwoServers = {
    expr =
      (dnfLib.resolveZoneService {
        name = "stk";
        host = nfsClientHost;
        hosts = nfsHosts;
        zone = mockZone;
        services = [
          {
            name = "stk";
            host = "nfssrv";
            zone = "lan";
          }
          {
            name = "stk";
            host = "otherhost";
            zone = "lan";
          }
        ];
      }).count;
    expected = 2;
  };
}
