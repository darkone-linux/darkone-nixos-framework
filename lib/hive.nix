# Pure helpers for flake.nix host/node wiring.
#
# Extracted from flake.nix to be unit-testable and reusable in NixOS modules
# via specialArgs.dnfLib. Note: flake.nix imports this file directly
# (system-independent) to avoid the circular dependency with mkDnfLib.

{ lib }:
{
  # CPU architecture for a host, defaulting to x86_64-linux.
  getHostArch = host: lib.attrByPath [ "arch" ] "x86_64-linux" host;

  # Build the specialArgs/extraSpecialArgs attribute set for a NixOS host node.
  # Computes the zone from network and merges any extra args (pkgs-stable, dnfLib, etc.).
  mkNodeArgs =
    {
      host,
      hosts,
      network,
      extraArgs ? { },
    }:
    {
      inherit host hosts network;
      zone = network.zones.${host.zone};
    }
    // extraArgs;
}
