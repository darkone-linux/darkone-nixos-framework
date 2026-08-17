# Pure helpers for flake.nix host/node wiring.
#
# Extracted from flake.nix to be unit-testable and reusable in NixOS modules
# via specialArgs.dnfLib. Note: flake.nix imports this file directly
# (system-independent) to avoid the circular dependency with mkDnfLib.

{ lib }:
let

  # Compact `arch` token → nixos-raspberrypi board module name. The generator
  # whitelist (dnf-generator) is the first guard, but a hand-written
  # `var/generated/hosts.nix` bypasses it — hence the validation below.
  boardModuleNames = {
    rpi02 = "raspberry-pi-02";
    rpi3 = "raspberry-pi-3";
    rpi4 = "raspberry-pi-4";
    rpi5 = "raspberry-pi-5";
  };

  # CPU half of `arch`, mirroring `supportedSystems` in mk-configuration.nix.
  supportedCpus = [
    "x86_64"
    "aarch64"
  ];

  known = names: lib.concatStringsSep ", " (lib.sort (a: b: a < b) names);

  # Parse the single `arch` field (`cpu[:board]`) into a NixOS system + optional
  # board. Accepts the legacy `x86_64-linux` full form as an alias of `x86_64`.
  #
  # - null / "x86_64" / "x86_64-linux" → { system = "x86_64-linux"; board = null; }
  # - "aarch64:rpi5"                   → { system = "aarch64-linux"; board = "raspberry-pi-5"; }
  #
  # Both halves are validated: a bad CPU used to surface much later as an
  # unrelated stdenv failure, and a bad board token silently degraded a Pi to a
  # generic aarch64 build — no vendor kernel, no firmware, no bootloader, and an
  # image that simply does not boot.
  parseArch =
    arch:
    let
      raw = if arch == null then "x86_64" else arch;
      parts = lib.splitString ":" raw;
      cpu = lib.removeSuffix "-linux" (builtins.head parts);
      token = if builtins.length parts > 1 then builtins.elemAt parts 1 else null;
    in
    lib.throwIf (!lib.elem cpu supportedCpus)
      "DNF: unsupported CPU `${cpu}` in arch `${raw}` (expected one of: ${known supportedCpus}). Syntax: `cpu[:board]`."
      lib.throwIf
      (token != null && !(boardModuleNames ? ${token}))
      "DNF: unknown board `${toString token}` in arch `${raw}` (known boards: ${known (builtins.attrNames boardModuleNames)})."
      {
        system = "${cpu}-linux";
        board = if token == null then null else boardModuleNames.${token};
      };
in
{
  inherit parseArch;

  # CPU architecture for a host, defaulting to x86_64-linux.
  getHostArch = host: (parseArch (host.arch or null)).system;

  # Raspberry Pi board module name for a host (e.g. "raspberry-pi-5"), or null
  # when the host is not a board target. Drives the conditional nixos-raspberrypi
  # module injection in mkNode; null keeps the standard x86 path untouched.
  getHostBoard = host: (parseArch (host.arch or null)).board;

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
