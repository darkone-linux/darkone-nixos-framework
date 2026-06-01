# Tests for dnf/lib/firewall.nix
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
in
{

  # ----- getInternalInterfaceFwPath -----
  testFwPathGateway = {
    expr = dnfLib.getInternalInterfaceFwPath mockHost mockZone;
    expected = [
      "interfaces"
      constants.lanInterface
    ];
  };
  testFwPathVpnClient = {
    expr = dnfLib.getInternalInterfaceFwPath (mockHost // { vpnIp = "100.64.1.1"; }) mockZone;
    expected = [
      "interfaces"
      constants.vpnInterface
    ];
  };
  testFwPathRegularHost = {
    expr = dnfLib.getInternalInterfaceFwPath (mockHost // { hostname = "otherhost"; }) mockZone;
    expected = [ ];
  };

  # Regression: empty vpnIp should not be classified as VPN client
  testFwPathVpnEmptyIp = {
    expr = dnfLib.getInternalInterfaceFwPath (
      mockHost
      // {
        hostname = "otherhost";
        vpnIp = "";
      }
    ) mockZone;
    expected = [ ];
  };

  # ----- mkInternalFirewall -----
  # Non-gateway, non-VPN host: root path, active ports (mkIf true)
  testMkInternalFirewallRegular = {
    expr =
      let
        fw = dnfLib.mkInternalFirewall (mockHost // { hostname = "otherhost"; }) mockZone [ 3000 ];
        v = fw.allowedTCPPorts;
      in
      {
        inherit (v) _type condition content;
      };
    expected = {
      _type = "if";
      condition = true;
      content = [ 3000 ];
    };
  };

  # Gateway: path = [interfaces lan0], disabled ports (mkIf false)
  # Inspect the produced `mkIf` structure without relying on `lib`.
  testMkInternalFirewallGateway = {
    expr =
      let
        fw = dnfLib.mkInternalFirewall mockHost mockZone [ 3000 ];
        v = fw.interfaces.${constants.lanInterface}.allowedTCPPorts;
      in
      {
        inherit (v) _type condition content;
      };
    expected = {
      _type = "if";
      condition = false;
      content = [ 3000 ];
    };
  };

  # VPN client: path = [interfaces tailscale0]
  testMkInternalFirewallVpn = {
    expr =
      let
        h = mockHost // {
          hostname = "vpnhost";
          vpnIp = "100.64.1.5";
        };
        fw = dnfLib.mkInternalFirewall h mockZone [ 8080 ];
        v = fw.interfaces.${constants.vpnInterface}.allowedTCPPorts;
      in
      {
        inherit (v) _type condition content;
      };
    expected = {
      _type = "if";
      condition = true;
      content = [ 8080 ];
    };
  };
}
