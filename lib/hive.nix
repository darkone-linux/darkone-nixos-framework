# Pure helpers for flake.nix host/node wiring.
#
# Extracted from flake.nix to be unit-testable and reusable in NixOS modules
# via specialArgs.dnfLib. Note: flake.nix imports this file directly
# (system-independent) to avoid the circular dependency with mkDnfLib.

{ lib }: {
  # CPU architecture for a host, defaulting to x86_64-linux.
  getHostArch = host: lib.attrByPath [ "arch" ] "x86_64-linux" host;

  # Raspberry Pi board model for a host (e.g. "raspberry-pi-5"), or null when the
  # host is not a board target. Drives the conditional nixos-raspberrypi module
  # injection in mkNode; null keeps the standard x86 path untouched.
  getHostBoard = host: lib.attrByPath [ "board" ] null host;

  # NixOS modules to import for a Raspberry Pi board, replicating manually what
  # `nixos-raspberrypi.lib.nixosSystem` does (the wrapper is incompatible with
  # colmena's own evaluation). Kept pure: the flake is passed in as an argument.
  #
  # - inject-overlays   : RPi vendor kernel/firmware/bootloader packages
  # - trusted-nix-caches: upstream binary cache for prebuilt RPi packages
  # - <board>.base      : board-specific hardware configuration
  rpiBoardModules = nixos-raspberrypi: board: [
    nixos-raspberrypi.lib.inject-overlays
    nixos-raspberrypi.nixosModules.trusted-nix-caches
    nixos-raspberrypi.nixosModules.${board}.base
  ];

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
