# Tests for dnf/lib/service-params.nix
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

  hcsHost = {
    hostname = "hcshost";
    zone = constants.globalZone;
    networkDomain = "example.com";
    zoneDomain = "example.com";
    ip = "203.0.113.1";
  };

  vpnHost = mockHost // {
    hostname = "vpnhost";
    vpnIp = "100.64.1.5";
  };

  mockNetworkPlain = {
    coordination.enable = false;
    services = [ ];
  };

  mockNetworkHcs = {
    coordination = {
      enable = true;
      hostname = "hcshost";
    };
    services = [ ];
  };

  otherHost = {
    hostname = "otherhost";
    zone = "dmz";
    networkDomain = "example.com";
    zoneDomain = "dmz.example.com";
    ip = "192.168.2.10";
  };

  mockHosts = [
    mockHost
    otherHost
    hcsHost
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

  # ----- buildServiceParams: local service, full defaults -----
  testBuildServiceParamsLocal = {
    expr =
      let
        p = dnfLib.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } { };
      in
      {
        inherit (p)
          domain
          title
          icon
          fqdn
          href
          ip
          global
          ;
      };
    expected = {
      domain = "wiki";
      title = "Wiki";
      icon = "sh-wiki";
      fqdn = "wiki.lan.example.com";
      href = "http://wiki.lan.example.com";
      ip = "192.168.1.10";
      global = false;
    };
  };

  # ----- buildServiceParams: cascade to defaults -----
  testBuildServiceParamsCascadeDefaults = {
    expr =
      let
        p = dnfLib.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } {
          domain = "knowledge";
          title = "Knowledge Base";
          description = "Internal docs";
        };
      in
      {
        inherit (p) domain title description;
      };
    expected = {
      domain = "knowledge";
      title = "Knowledge Base";
      description = "Internal docs";
    };
  };

  # ----- buildServiceParams: derived fallbacks -----
  testBuildServiceParamsDerivedFallbacks = {
    expr =
      let
        p = dnfLib.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } { };
      in
      {
        inherit (p)
          description
          noRobots
          zone
          host
          ;
      };
    expected = {
      description = "Wiki local service";
      noRobots = true;
      zone = "lan";
      host = "testhost";
    };
  };

  # ----- buildServiceParams: empty module defaults count as unset -----
  testBuildServiceParamsEmptyDefaults = {
    expr =
      let
        p = dnfLib.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } {
          domain = "";
          title = "";
          icon = "";
          ip = "";
        };
      in
      {
        inherit (p)
          domain
          title
          icon
          ip
          ;
      };
    expected = {
      domain = "wiki";
      title = "Wiki";
      icon = "sh-wiki";
      ip = "192.168.1.10";
    };
  };

  # ----- buildServiceParams: the network entry wins over module defaults -----
  testBuildServiceParamsEntryWins = {
    expr =
      let
        p =
          dnfLib.buildServiceParams mockHost mockNetworkPlain
            {
              name = "wiki";
              domain = "kb";
              icon = "bookstack";
              global = false;
              noRobots = false;
              zone = "dmz";
              host = "otherhost";
            }
            {
              domain = "knowledge";
              icon = "wikijs";
              global = true;
              noRobots = true;
            };
      in
      {
        inherit (p)
          domain
          icon
          global
          noRobots
          zone
          host
          fqdn
          ;
      };
    expected = {
      domain = "kb";
      icon = "sh-bookstack";
      global = false;
      noRobots = false;
      zone = "dmz";
      host = "otherhost";
      fqdn = "kb.lan.example.com";
    };
  };

  # ----- buildServiceParams: boolean module defaults apply, even `false` -----
  testBuildServiceParamsBooleanDefaults = {
    expr =
      let
        p = dnfLib.buildServiceParams hcsHost mockNetworkHcs { name = "site"; } {
          global = true;
          noRobots = false;
        };
      in
      {
        inherit (p) global noRobots fqdn;
      };
    expected = {
      global = true;
      noRobots = false;
      fqdn = "site.example.com";
    };
  };

  # ----- buildServiceParams: an explicit IP beats the topology -----
  testBuildServiceParamsExplicitIp = {
    expr = {
      fromDefaults =
        (dnfLib.buildServiceParams hcsHost mockNetworkHcs { name = "auth"; } { ip = "10.0.0.5"; }).ip;
      fromEntry =
        (dnfLib.buildServiceParams hcsHost mockNetworkHcs {
          name = "auth";
          ip = "10.0.0.6";
        } { ip = "10.0.0.5"; }).ip;
    };
    expected = {
      fromDefaults = "10.0.0.5";
      fromEntry = "10.0.0.6";
    };
  };

  # ----- buildServiceParams: global service uses networkDomain -----
  testBuildServiceParamsGlobalFqdn = {
    expr =
      let
        p = dnfLib.buildServiceParams hcsHost mockNetworkHcs {
          name = "site";
          global = true;
        } { };
      in
      {
        inherit (p) fqdn href global;
      };
    expected = {
      fqdn = "site.example.com";
      href = "https://site.example.com";
      global = true;
    };
  };

  # ----- buildServiceParams: HCS resolves to loopback -----
  testBuildServiceParamsHcsLoopback = {
    expr = (dnfLib.buildServiceParams hcsHost mockNetworkHcs { name = "auth"; } { }).ip;
    expected = "127.0.0.1";
  };

  # ----- buildServiceParams: VPN client with vpnIp -----
  testBuildServiceParamsVpnIp = {
    expr = (dnfLib.buildServiceParams vpnHost mockNetworkHcs { name = "remote"; } { }).ip;
    expected = "100.64.1.5";
  };

  # ----- buildServiceParams: empty vpnIp falls back to host.ip -----
  testBuildServiceParamsEmptyVpnIp = {
    expr =
      (dnfLib.buildServiceParams (mockHost // { vpnIp = ""; }) mockNetworkPlain { name = "svc"; } { }).ip;
    expected = "192.168.1.10";
  };

  # ----- extractServiceParams: service found -----
  testExtractServiceParamsFound = {
    expr =
      let
        net = mockNetworkPlain // {
          services = mockServices;
        };
        p = dnfLib.extractServiceParams mockHost net "wiki" { description = "default desc"; };
      in
      {
        inherit (p) domain zone host;
      };
    expected = {
      domain = "wiki";
      zone = "lan";
      host = "testhost";
    };
  };

  # ----- extractServiceParams: missing service falls back to defaults -----
  testExtractServiceParamsMissing = {
    expr =
      let
        net = mockNetworkPlain // {
          services = mockServices;
        };
        p = dnfLib.extractServiceParams mockHost net "ghost" { domain = "ghosts"; };
      in
      {
        inherit (p) domain zone;
      };
    expected = {
      domain = "ghosts";
      zone = "lan";
    };
  };

  # ----- serviceHref: service not deployed -----
  testServiceHrefMissing = {
    expr = dnfLib.serviceHref {
      name = "ghost";
      network = mockNetworkPlain // {
        services = mockServices;
      };
      hosts = mockHosts;
    };
    expected = null;
  };

  # ----- serviceHref: first declared instance wins without preferZone -----
  testServiceHrefFirstInstance = {
    expr = dnfLib.serviceHref {
      name = "wiki";
      network = mockNetworkPlain // {
        services = mockServices;
      };
      hosts = mockHosts;
    };
    expected = "http://wiki.lan.example.com";
  };

  # ----- serviceHref: preferZone picks the caller's own instance -----
  testServiceHrefPreferZone = {
    expr = dnfLib.serviceHref {
      name = "wiki";
      network = mockNetworkPlain // {
        services = mockServices;
      };
      hosts = mockHosts;
      preferZone = "dmz";
    };
    expected = "http://wiki.dmz.example.com";
  };

  # ----- serviceHref: unmatched preferZone falls back to the first instance -----
  testServiceHrefPreferZoneFallback = {
    expr = dnfLib.serviceHref {
      name = "wiki";
      network = mockNetworkPlain // {
        services = mockServices;
      };
      hosts = mockHosts;
      preferZone = "nowhere";
    };
    expected = "http://wiki.lan.example.com";
  };

  # ----- serviceHref: global service resolves on the network domain -----
  testServiceHrefGlobal = {
    expr = dnfLib.serviceHref {
      name = "global-svc";
      network = mockNetworkPlain // {
        services = mockServices;
      };
      hosts = mockHosts;
    };
    expected = "http://global-svc.example.com";
  };

  # ----- serviceHref: module defaults feed the sub-domain -----
  testServiceHrefDefaults = {
    expr = dnfLib.serviceHref {
      name = "wiki";
      network = mockNetworkPlain // {
        services = mockServices;
      };
      hosts = mockHosts;
      defaults.domain = "knowledge";
    };
    expected = "http://knowledge.lan.example.com";
  };

  # ----- enableBlock -----
  testEnableBlock = {
    expr = dnfLib.enableBlock "forgejo";
    expected = {
      enable = true;
      service.forgejo.enable = true;
    };
  };
}
