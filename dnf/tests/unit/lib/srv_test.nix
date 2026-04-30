# Tests for dnf/lib/srv.nix
# Run with: nix eval --impure --expr 'let lib = (import <nixpkgs> {}).lib; in import ./dnf/tests/unit/lib/srv_test.nix { inherit lib; }'

{ lib }:
let
  strings = import ../../../lib/strings.nix { inherit lib; };
  srv = import ../../../lib/srv.nix { inherit lib strings; };

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
in
{
  result =
    check "isVpnClientTrue" (srv.isVpnClient { vpnIp = "100.64.1.1"; })
    + " | "
    + check "isVpnClientFalse" (!srv.isVpnClient { hostname = "testhost"; })
    + " | "
    + check "inLocalZoneTrue" (srv.inLocalZone { name = "lan"; })
    + " | "
    + check "inLocalZoneFalse" (!srv.inLocalZone { name = "www"; })
    + " | "
    + check "isGatewayTrue" (srv.isGateway mockHost mockZone)
    + " | "
    + check "isGatewayFalseNotGateway" (
      !srv.isGateway (mockHost // { hostname = "otherhost"; }) mockZone
    )
    + " | "
    + check "isGatewayFalseVpnClient" (!srv.isGateway (mockHost // { vpnIp = "100.64.1.1"; }) mockZone)
    + " | "
    + check "fwPathGateway" (
      srv.getInternalInterfaceFwPath mockHost mockZone == [
        "interfaces"
        "lan0"
      ]
    )
    + " | "
    + check "fwPathVpnClient" (
      srv.getInternalInterfaceFwPath (mockHost // { vpnIp = "100.64.1.1"; }) mockZone == [
        "interfaces"
        "tailscale0"
      ]
    )
    + " | "
    + check "fwPathRegularHost" (
      srv.getInternalInterfaceFwPath (mockHost // { hostname = "otherhost"; }) mockZone == [ ]
    );
}
