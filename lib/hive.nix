# DNF — host/node wiring helpers (arch parsing, RPi boards, node args).
#
# Imported directly by `lib/mk-configuration.nix`, which needs them before the
# per-system `dnfLib` exists; also exposed through `dnfLib` for unit tests.

{ lib }:
let

  # Compact `arch` token → nixos-raspberrypi board module name. Validated
  # below too: a hand-written `var/generated/hosts.nix` bypasses the
  # dnf-generator whitelist.
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

  # `arch` (`cpu[:board]`, legacy `x86_64-linux` accepted) → system + board:
  #   null / "x86_64" → { system = "x86_64-linux"; board = null; }
  #   "aarch64:rpi5"  → { system = "aarch64-linux"; board = "raspberry-pi-5"; }
  # Both halves throw when unknown: a bad board would build a generic aarch64
  # image that never boots.
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

  # Every supported board module name (one SD image each).
  rpiBoards = builtins.attrValues boardModuleNames;

  # CPU architecture for a host, defaulting to x86_64-linux.
  getHostArch = host: (parseArch (host.arch or null)).system;

  # Raspberry Pi board module name for a host (e.g. "raspberry-pi-5"), or null
  # when the host is not a board target. Drives the conditional nixos-raspberrypi
  # module injection in mkNode; null keeps the standard x86 path untouched.
  getHostBoard = host: (parseArch (host.arch or null)).board;

  # What `nixos-raspberrypi.lib.nixosSystem` imports for a board, which colmena
  # cannot use: vendor packages overlay, upstream binary cache, board hardware.
  rpiBoardModules = nixos-raspberrypi: board: [
    nixos-raspberrypi.lib.inject-overlays
    nixos-raspberrypi.nixosModules.trusted-nix-caches
    nixos-raspberrypi.nixosModules.${board}.base
  ];

  # `specialArgs` of a host node: inventory, its zone, then `extraArgs`.
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
