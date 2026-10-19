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

  # Kanidm group of an AI space: its members reach the space's services
  # (`proxy.spaceMembersOnly`).
  spaceGroup = hostname: "space-${hostname}";

  # Members of an AI space: its host's `users`, minus `nix` (technical
  # account the generator adds everywhere).
  spaceMembers = host: lib.remove "nix" (host.users or [ ]);

  isSpaceHost = host: (host.profile or null) == "ai-space";

  # A member's account on its space is light: no sudo, `space-member` home
  # instead of its own profile (`lib/mk-configuration.nix`).
  isSpaceMember = host: login: isSpaceHost host && lib.elem login (spaceMembers host);

  # Hypervisor of a microVM guest (`features: ["microvm-guest:<host>"]`), or
  # null. A bare feature defaults its value to the zone name, not a hostname:
  # the value is checked against the inventory.
  getMicrovmHypervisor =
    hosts: host:
    let
      name = (host.features or { }).microvm-guest or null;
      candidates = map (h: h.hostname) (lib.filter (h: h.hostname != host.hostname) hosts);
    in
    if name == null then
      null
    else
      lib.throwIf (!lib.elem name candidates)
        "DNF: `${host.hostname}`: feature `microvm-guest:${name}` names no other host (syntax: `microvm-guest:<hypervisor-hostname>`)."
        name;

  # Two-digit lowercase hex of a decimal IPv4 octet.
  hexOctet =
    octet:
    let
      hex = lib.toLower (lib.toHexString (lib.toInt octet));
    in
    if builtins.stringLength hex == 1 then "0${hex}" else hex;

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

  inherit getMicrovmHypervisor;

  # Hostnames of the microVM guests a host runs (empty: not a hypervisor).
  getMicrovmGuests =
    hosts: hostname:
    map (h: h.hostname) (lib.filter (h: getMicrovmHypervisor hosts h == hostname) hosts);

  # Tap name, MAC and vsock CID of a guest, derived from its fixed zone IP:
  # unique on the hypervisor, stable, no extra config key. Tap names cap at 15
  # chars (`vm-255-255` is 10). `02:` = locally administered unicast MAC.
  # CID: last two octets + 3, CIDs 0-2 are reserved.
  mkMicrovmLink =
    host:
    let
      ip = host.ip or null;
      octets = lib.splitString "." ip;
    in
    lib.throwIf (ip == null)
      "DNF: microVM guest `${host.hostname}` needs a fixed IP (`zone: \"<zone>:X.Y\"`)."
      {
        tap = "vm-${builtins.elemAt octets 2}-${builtins.elemAt octets 3}";
        mac = "02:00:" + lib.concatMapStringsSep ":" hexOctet octets;
        cid = lib.toInt (builtins.elemAt octets 2) * 256 + lib.toInt (builtins.elemAt octets 3) + 3;
      };

  inherit
    spaceGroup
    spaceMembers
    isSpaceHost
    isSpaceMember
    ;

  # One members list per `ai-space` host, keyed by its group (no Linux
  # account implied).
  mkSpaceGroups =
    hosts:
    lib.listToAttrs (
      map (h: lib.nameValuePair (spaceGroup h.hostname) (spaceMembers h)) (lib.filter isSpaceHost hosts)
    );

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
