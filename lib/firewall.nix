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
  inherit (topology)
    isGateway
    isVpnClient
    ;
in
rec {

  # Path inside `networking.firewall` selecting the internal interface to
  # which a service should be exposed. Returns `[]` for hosts that have no
  # internal interface (eg. external clients without VPN).
  #
  # Usage:
  #   networking.firewall = lib.setAttrByPath
  #     (dnfLib.getInternalInterfaceFwPath host zone)
  #     { allowedTCPPorts = [ port ]; };
  getInternalInterfaceFwPath =
    host: zone:
    if (isGateway host zone) then
      [
        "interfaces"
        constants.lanInterface
      ]
    else
      (
        if (isVpnClient host) then
          [
            "interfaces"
            constants.vpnInterface
          ]
        else
          [ ]
      );

  # Firewall fragment opening `ports` on the internal interface of `host`
  # in `zone`. The port list is only effective on non-gateway hosts: on a
  # gateway, traffic flows through the reverse proxy so the service port
  # stays closed on the internal interface.
  #
  # Returns a complete `networking.firewall` fragment ready to assign:
  #
  #   networking.firewall = dnfLib.mkInternalFirewall host zone [ port ];
  mkInternalFirewall =
    host: zone: ports:
    lib.setAttrByPath (getInternalInterfaceFwPath host zone) {
      allowedTCPPorts = lib.mkIf (!(isGateway host zone)) ports;
    };
}
