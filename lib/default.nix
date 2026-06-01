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
  topology = import ./topology.nix { inherit lib constants; };
  serviceParams = import ./service-params.nix { inherit lib strings; };
  firewall = import ./firewall.nix { inherit lib constants topology; };
  oidc = import ./oidc.nix { inherit lib topology serviceParams; };
  homepage = import ./homepage.nix { inherit lib constants; };
  security = import ./security.nix { inherit lib; };
  hive = import ./hive.nix { inherit lib; };
  paths = import ./paths.nix { inherit lib; };
  serviceActivation = import ./service-activation.nix { inherit lib; };
in
{
  inherit constants;
  inherit (strings) ucFirst cleanString mkCaddySecurityHeaders;
  inherit (security) mkIsActive levelMapping;
  inherit (hive) getHostArch mkNodeArgs;
  inherit (paths) resolveProfile resolveNixosProfile;
  inherit (serviceActivation) triggerProfileServices mkHostProfileServicesAssertions;
  inherit (topology)
    findHost
    findService
    isVpnClient
    isGateway
    inLocalZone
    isHcs
    preferredIp
    ;
  inherit (serviceParams) buildServiceParams extractServiceParams enableBlock;
  inherit (firewall) getInternalInterfaceFwPath mkInternalFirewall;
  inherit (oidc)
    oauth2ClientName
    idmHref
    mkOidcContext
    mkOauth2Clients
    mkKanidmEndpoints
    ;
  inherit (homepage) mkHomepageSection;
}
