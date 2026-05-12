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
  security = import ./security.nix { inherit lib; };
  hive = import ./hive.nix { inherit lib; };
in
{
  inherit constants;
  inherit (strings) ucFirst cleanString mkCaddySecurityHeaders;
  inherit (security) mkIsActive levelMapping;
  inherit (hive) getHostArch mkNodeArgs;
  inherit (srv)
    findHost
    findService
    buildServiceParams
    extractServiceParams
    oauth2ClientName
    idmHref
    isVpnClient
    isGateway
    inLocalZone
    isHcs
    getInternalInterfaceFwPath
    preferredIp
    mkInternalFirewall
    mkOidcContext
    mkOauth2Clients
    mkKanidmEndpoints
    enableBlock
    mkHomepageSection
    ;
}
