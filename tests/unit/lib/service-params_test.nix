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

  # ----- enableBlock -----
  testEnableBlock = {
    expr = dnfLib.enableBlock "forgejo";
    expected = {
      enable = true;
      service.forgejo.enable = true;
    };
  };
}
