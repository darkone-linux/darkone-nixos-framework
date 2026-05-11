# Tests for dnf/lib/srv.nix
# Run with: nix-unit --flake .#libTests
{ lib, dnfLib }:
let
  constants = dnfLib.constants;

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

  mockHosts = [
    mockHost
    (mockHost // { hostname = "otherhost"; zone = "dmz"; })
    hcsHost
  ];

  mockServices = [
    { name = "wiki"; host = "testhost"; zone = "lan"; }
    { name = "wiki"; host = "otherhost"; zone = "dmz"; }
    { name = "global-svc"; host = "hcshost"; zone = constants.globalZone; global = true; }
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

  # ----- getInternalInterfaceFwPath -----
  testFwPathGateway = {
    expr = dnfLib.getInternalInterfaceFwPath mockHost mockZone;
    expected = [ "interfaces" constants.lanInterface ];
  };
  testFwPathVpnClient = {
    expr = dnfLib.getInternalInterfaceFwPath (mockHost // { vpnIp = "100.64.1.1"; }) mockZone;
    expected = [ "interfaces" constants.vpnInterface ];
  };
  testFwPathRegularHost = {
    expr = dnfLib.getInternalInterfaceFwPath (mockHost // { hostname = "otherhost"; }) mockZone;
    expected = [ ];
  };
  # Régression : vpnIp vide ne doit pas être classé comme client VPN
  testFwPathVpnEmptyIp = {
    expr = dnfLib.getInternalInterfaceFwPath (mockHost // { hostname = "otherhost"; vpnIp = ""; }) mockZone;
    expected = [ ];
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

  # ----- buildServiceParams : service local, defaults complets -----
  testBuildServiceParamsLocal = {
    expr =
      let p = dnfLib.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } { };
      in { inherit (p) domain title icon fqdn href ip global; };
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

  # ----- buildServiceParams : cascade vers defaults -----
  testBuildServiceParamsCascadeDefaults = {
    expr =
      let
        p = dnfLib.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } {
          domain = "knowledge";
          title = "Knowledge Base";
          description = "Internal docs";
        };
      in
      { inherit (p) domain title description; };
    expected = {
      domain = "knowledge";
      title = "Knowledge Base";
      description = "Internal docs";
    };
  };

  # ----- buildServiceParams : service global utilise networkDomain -----
  testBuildServiceParamsGlobalFqdn = {
    expr =
      let p = dnfLib.buildServiceParams hcsHost mockNetworkHcs { name = "site"; global = true; } { };
      in { inherit (p) fqdn href global; };
    expected = {
      fqdn = "site.example.com";
      href = "https://site.example.com";
      global = true;
    };
  };

  # ----- buildServiceParams : HCS résout sur loopback -----
  testBuildServiceParamsHcsLoopback = {
    expr = (dnfLib.buildServiceParams hcsHost mockNetworkHcs { name = "auth"; } { }).ip;
    expected = "127.0.0.1";
  };

  # ----- buildServiceParams : client VPN avec vpnIp -----
  testBuildServiceParamsVpnIp = {
    expr = (dnfLib.buildServiceParams vpnHost mockNetworkHcs { name = "remote"; } { }).ip;
    expected = "100.64.1.5";
  };

  # ----- buildServiceParams : vpnIp vide retombe sur host.ip -----
  testBuildServiceParamsEmptyVpnIp = {
    expr = (dnfLib.buildServiceParams (mockHost // { vpnIp = ""; }) mockNetworkPlain { name = "svc"; } { }).ip;
    expected = "192.168.1.10";
  };

  # ----- extractServiceParams : service trouvé -----
  testExtractServiceParamsFound = {
    expr =
      let
        net = mockNetworkPlain // { services = mockServices; };
        p = dnfLib.extractServiceParams mockHost net "wiki" { description = "default desc"; };
      in
      { inherit (p) domain zone host; };
    expected = { domain = "wiki"; zone = "lan"; host = "testhost"; };
  };

  # ----- extractServiceParams : service inexistant retombe sur defaults -----
  testExtractServiceParamsMissing = {
    expr =
      let
        net = mockNetworkPlain // { services = mockServices; };
        p = dnfLib.extractServiceParams mockHost net "ghost" { domain = "ghosts"; };
      in
      { inherit (p) domain zone; };
    expected = { domain = "ghosts"; zone = "lan"; };
  };

  # ----- oauth2ClientName -----
  testOauth2NameDefault = {
    expr = dnfLib.oauth2ClientName { name = "forgejo"; } { domain = "forgejo"; };
    expected = "forgejo";
  };
  testOauth2NameRenamedDomain = {
    expr = dnfLib.oauth2ClientName { name = "outline"; } { domain = "notes"; };
    expected = "outline-notes";
  };
  testOauth2NameOverride = {
    expr = dnfLib.oauth2ClientName { name = "matrix"; clientName = "matrix-synapse"; } { domain = "matrix"; };
    expected = "matrix-synapse";
  };
  # clientName explicitement null → règle par défaut
  testOauth2NameNullOverride = {
    expr = dnfLib.oauth2ClientName { name = "mealie"; clientName = null; } { domain = "mealie"; };
    expected = "mealie";
  };

  # ----- idmHref -----
  testIdmHrefPresent = {
    expr =
      let
        net = mockNetworkHcs // {
          services = [ { name = "idm"; host = "hcshost"; zone = constants.globalZone; global = true; } ];
        };
      in
      dnfLib.idmHref net mockHosts;
    expected = "https://idm.example.com";
  };
  testIdmHrefMissing = {
    expr = dnfLib.idmHref (mockNetworkHcs // { services = mockServices; }) mockHosts;
    expected = null;
  };
}
