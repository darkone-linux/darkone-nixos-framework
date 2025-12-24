{ lib }:

let
  strings = import ./strings.nix { inherit lib; };
  srv = import ./srv.nix { inherit lib strings; };
in
{
  inherit (strings) ucFirst;
  inherit (srv) buildServiceParams;
  inherit (srv) extractServiceParams;
  inherit (srv) isVpnClient;
  inherit (srv) isGateway;
  inherit (srv) inLocalZone;
  inherit (srv) isHcs;
  inherit (srv) getInternalInterfaceFwPath;
}
