# DNF — install images: the installer ISO and the Raspberry Pi SD images.
#
# Built by the framework flake (generic ISO, `darkone new` assistant) and by
# `mk-configuration.nix` (images carrying the consumer's deploy key, read
# through `workDir`).

{ inputs }:
let
  inherit (inputs) nixpkgs nixos-raspberrypi;

  # An install image is not a host of the inventory yet: neutral identity.
  placeholderHost = system: {
    hostname = "new-dnf-host";
    name = "New Darkone NixOS Framework";
    profile = "minimal";
    users = [ ];
    groups = [ ];
    arch = system;
  };
in
{

  # `iso-<system>`. `installer`: the `darkone new` assistant, or null.
  # `workDir`: consumer workspace, or null for the generic image (`iso.nix`
  # declares `workDir ? null`, a default the module system never applies).
  mkIso =
    {
      system,
      pkgs,
      workDir,
      installer,
    }:
    nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit workDir installer;
        imgFormat = nixpkgs.lib.mkDefault "iso";
        host = placeholderHost system;
      };
      modules = [
        { nixpkgs.pkgs = pkgs; }
        ../../hosts/iso.nix
      ];
    };

  # `sd-image-<board>`, through the nixos-raspberrypi wrapper (no colmena
  # here): it applies the RPi overlays and injects its own specialArg.
  mkSdImage =
    { board, workDir }:
    nixos-raspberrypi.lib.nixosSystem {
      specialArgs = { inherit workDir nixos-raspberrypi; };
      modules = [
        nixos-raspberrypi.nixosModules.${board}.base
        nixos-raspberrypi.nixosModules.sd-image
        ../../hosts/sd-image.nix
      ];
    };
}
