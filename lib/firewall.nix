# DNF — internal-interface firewall fragments
#
# Builds `networking.firewall` fragments that expose service ports on the
# right internal interface (LAN on a gateway, tailscale on a VPN client),
# based on the host's role in the topology. Pure and side-effect free.

{
  lib,
  constants,
  topology,
}:
let
  inherit (topology) isGateway isVpnClient;
in
rec {

  # `networking.firewall` path of the internal interface of `host`: the LAN on
  # a gateway, the tailnet on a VPN client, `[ ]` (root) otherwise.
  getInternalInterfaceFwPath =
    host: zone:
    if isGateway host zone then
      [
        "interfaces"
        constants.lanInterface
      ]
    else if isVpnClient host then
      [
        "interfaces"
        constants.vpnInterface
      ]
    else
      [ ];

  # `networking.firewall` fragment opening `ports` on that interface. Left
  # closed on a gateway: there the reverse proxy fronts the service.
  #
  #   networking.firewall = dnfLib.mkInternalFirewall host zone [ port ];
  mkInternalFirewall =
    host: zone: ports:
    lib.setAttrByPath (getInternalInterfaceFwPath host zone) {
      allowedTCPPorts = lib.mkIf (!(isGateway host zone)) ports;
    };
}
