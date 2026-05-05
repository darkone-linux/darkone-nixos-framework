# Tests for dnf/lib/srv.nix
# Run with: nix eval --impure --expr 'let lib = (import <nixpkgs> {}).lib; in import ./dnf/tests/unit/lib/srv_test.nix { inherit lib; }'

{ lib }:
let
  constants = import ../../../lib/constants.nix;
  strings = import ../../../lib/strings.nix { inherit lib; };
  srv = import ../../../lib/srv.nix { inherit lib strings constants; };

  check = name: cond: if cond then "PASS: ${name}" else throw "FAIL: ${name}";

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
    (
      mockHost
      // {
        hostname = "otherhost";
        zone = "dmz";
      }
    )
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
  result =
    # ----- isVpnClient -----
    check "isVpnClientTrue" (srv.isVpnClient { vpnIp = "100.64.1.1"; })
    + " | "
    + check "isVpnClientFalseMissing" (!srv.isVpnClient { hostname = "testhost"; })
    + " | "
    + check "isVpnClientFalseEmpty" (!srv.isVpnClient { vpnIp = ""; })

    # ----- inLocalZone -----
    + " | "
    + check "inLocalZoneTrue" (srv.inLocalZone { name = "lan"; })
    + " | "
    + check "inLocalZoneFalse" (!srv.inLocalZone { name = constants.globalZone; })

    # ----- isGateway -----
    + " | "
    + check "isGatewayTrue" (srv.isGateway mockHost mockZone)
    + " | "
    + check "isGatewayFalseNotGateway" (
      !srv.isGateway (mockHost // { hostname = "otherhost"; }) mockZone
    )
    + " | "
    + check "isGatewayFalseVpnClient" (!srv.isGateway (mockHost // { vpnIp = "100.64.1.1"; }) mockZone)

    # ----- isHcs -----
    + " | "
    + check "isHcsTrue" (srv.isHcs hcsHost mockGlobalZone mockNetworkHcs)
    + " | "
    + check "isHcsFalseLocalZone" (!srv.isHcs hcsHost mockZone mockNetworkHcs)
    + " | "
    + check "isHcsFalseNoCoordination" (
      !srv.isHcs hcsHost mockGlobalZone (mockNetworkHcs // { coordination.enable = false; })
    )

    # ----- getInternalInterfaceFwPath -----
    + " | "
    + check "fwPathGateway" (
      srv.getInternalInterfaceFwPath mockHost mockZone == [
        "interfaces"
        constants.lanInterface
      ]
    )
    + " | "
    + check "fwPathVpnClient" (
      srv.getInternalInterfaceFwPath (mockHost // { vpnIp = "100.64.1.1"; }) mockZone == [
        "interfaces"
        constants.vpnInterface
      ]
    )
    + " | "
    + check "fwPathRegularHost" (
      srv.getInternalInterfaceFwPath (mockHost // { hostname = "otherhost"; }) mockZone == [ ]
    )
    + " | "
    + check "fwPathVpnEmptyIp" (

      # Regression: empty vpnIp must NOT be classified as VPN client.
      srv.getInternalInterfaceFwPath (
        mockHost
        // {
          hostname = "otherhost";
          vpnIp = "";
        }
      ) mockZone == [ ]
    )

    # ----- findHost -----
    + " | "
    + check "findHostFound" ((srv.findHost "testhost" "lan" mockHosts).hostname == "testhost")
    + " | "
    + check "findHostMissing" (srv.findHost "ghost" "lan" mockHosts == { })

    # ----- findService -----
    + " | "
    + check "findServiceFound" ((srv.findService "wiki" "lan" mockServices).host == "testhost")
    + " | "
    + check "findServiceMissing" (srv.findService "ghost" "lan" mockServices == null)

    # ----- buildServiceParams: local service, full defaults -----
    + " | "
    + check "buildParamsLocalDefaults" (
      let
        p = srv.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } { };
      in
      p.domain == "wiki"
      && p.title == "Wiki"
      && p.icon == "sh-wiki"
      && p.fqdn == "wiki.lan.example.com"
      && p.href == "http://wiki.lan.example.com"
      && p.ip == "192.168.1.10"
      && !p.global
    )

    # ----- buildServiceParams: cascade vers defaults -----
    + " | "
    + check "buildParamsCascadeDefaults" (
      let
        p = srv.buildServiceParams mockHost mockNetworkPlain { name = "wiki"; } {
          domain = "knowledge";
          title = "Knowledge Base";
          description = "Internal docs";
        };
      in
      p.domain == "knowledge" && p.title == "Knowledge Base" && p.description == "Internal docs"
    )

    # ----- buildServiceParams: global service utilise networkDomain -----
    + " | "
    + check "buildParamsGlobalFqdn" (
      let
        p = srv.buildServiceParams hcsHost mockNetworkHcs {
          name = "site";
          global = true;
        } { };
      in
      p.fqdn == "site.example.com" && p.href == "https://site.example.com" && p.global
    )

    # ----- buildServiceParams: HCS résout sur loopback -----
    + " | "
    + check "buildParamsHcsLoopback" (
      let
        p = srv.buildServiceParams hcsHost mockNetworkHcs { name = "auth"; } { };
      in
      p.ip == "127.0.0.1"
    )

    # ----- buildServiceParams: client VPN avec vpnIp -----
    + " | "
    + check "buildParamsVpnIp" (
      let
        p = srv.buildServiceParams vpnHost mockNetworkHcs { name = "remote"; } { };
      in
      p.ip == "100.64.1.5"
    )

    # ----- buildServiceParams: vpnIp vide retombe sur host.ip -----
    + " | "
    + check "buildParamsEmptyVpnIp" (
      let
        p = srv.buildServiceParams (mockHost // { vpnIp = ""; }) mockNetworkPlain { name = "svc"; } { };
      in
      p.ip == "192.168.1.10"
    )

    # ----- extractServiceParams: service trouvé -----
    + " | "
    + check "extractParamsFound" (
      let
        net = mockNetworkPlain // {
          services = mockServices;
        };
        p = srv.extractServiceParams mockHost net "wiki" { description = "default desc"; };
      in
      p.domain == "wiki" && p.zone == "lan" && p.host == "testhost"
    )

    # ----- extractServiceParams: service inexistant retombe sur defaults -----
    + " | "
    + check "extractParamsMissing" (
      let
        net = mockNetworkPlain // {
          services = mockServices;
        };
        p = srv.extractServiceParams mockHost net "ghost" { domain = "ghosts"; };
      in
      p.domain == "ghosts" && p.zone == "lan"
    )

    # ----- oauth2ClientName: domaine == nom du service -----
    + " | "
    + check "oauth2NameDefault" (
      srv.oauth2ClientName { name = "forgejo"; } { domain = "forgejo"; } == "forgejo"
    )

    # ----- oauth2ClientName: domaine personnalisé -> nom suffixé -----
    + " | "
    + check "oauth2NameRenamedDomain" (
      srv.oauth2ClientName { name = "outline"; } { domain = "notes"; } == "outline-notes"
    )

    # ----- oauth2ClientName: clientName override préservé -----
    + " | "
    + check "oauth2NameOverride" (
      srv.oauth2ClientName {
        name = "matrix";
        clientName = "matrix-synapse";
      } { domain = "matrix"; } == "matrix-synapse"
    )

    # ----- oauth2ClientName: clientName explicitement null -> règle par défaut -----
    + " | "
    + check "oauth2NameNullOverride" (
      srv.oauth2ClientName {
        name = "mealie";
        clientName = null;
      } { domain = "mealie"; } == "mealie"
    )

    # ----- idmHref: idm trouvé dans les services -----
    + " | "
    + check "idmHrefPresent" (
      let
        net = mockNetworkHcs // {
          services = [
            {
              name = "idm";
              host = "hcshost";
              zone = constants.globalZone;
              global = true;
            }
          ];
        };
      in
      srv.idmHref net mockHosts == "https://idm.example.com"
    )

    # ----- idmHref: pas d'idm -> null -----
    + " | "
    + check "idmHrefMissing" (
      srv.idmHref (mockNetworkHcs // { services = mockServices; }) mockHosts == null
    );
}
