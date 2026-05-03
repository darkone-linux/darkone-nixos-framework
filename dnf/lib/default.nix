# DNF — internal Nix library (`dnfLib`)
#
# Public entry point of the helpers shared across DNF NixOS modules and
# home-manager modules. Imported once per system architecture by `flake.nix`
# (`mkDnfLib`) and injected into modules via `specialArgs.dnfLib` /
# `extraSpecialArgs.dnfLib`.

{ lib }:

let
  constants = import ./constants.nix;
  strings = import ./strings.nix { inherit lib; };
  srv = import ./srv.nix { inherit lib strings constants; };
in
{
  inherit constants;
  inherit (strings) ucFirst cleanString;
  inherit (srv)
    findHost
    findService
    buildServiceParams
    extractServiceParams
    isVpnClient
    isGateway
    inLocalZone
    isHcs
    getInternalInterfaceFwPath
    ;
}
