# L2 — single-node simulation. Replugs one workspace host into the NixOS
# Test Driver (see spec §8/§9.2).
#
# :::tip[Opt-in LAN]
# Set `lan = true;` when the module under test binds to `host.ip` (e.g.
# immich's `services.immich.host`). The helper then brings up the host's
# DNF zone VLAN on `eth1` and statically pins `host.ip` there, so the
# bind path stays identical to production. Off by default — existing
# scenarios (forgejo, fail2ban, ...) bind on `0.0.0.0`/`localhost` and
# don't need the extra plumbing.
# :::
#
# Aim: use.

{ pkgs, inputs }:
{
  name,
  workspace,
  host,
  testModule ? { },
  testScript,
  lan ? false,
}:
let
  inherit (pkgs) lib;
  vlans = import ./vlans.nix { inherit lib; };
  ws = import ./workspace.nix { inherit inputs; } workspace;
  nodeDef = ws.nodeOf host;
  hostRec = ws.hostByName host;

  # LAN seam: keep DNF networking unchanged but make the host.ip actually
  # exist on a local interface, otherwise services that bind to it fail
  # with EADDRNOTAVAIL and loop on systemd `Restart=on-failure`.
  lanModule = {
    virtualisation.vlans = [ (vlans.zoneVlans.${hostRec.zone} or 1) ];

    # The test driver's qemu-vm layer enables DHCP on every vlan NIC;
    # `mkForce` so the static address wins the merge cleanly.
    networking.interfaces.eth1 = {
      useDHCP = lib.mkForce false;
      ipv4.addresses = lib.mkForce [
        {
          address = hostRec.ip;
          prefixLength = 24;
        }
      ];
    };
  };
in
pkgs.testers.runNixOSTest {
  inherit name testScript;

  # DNF modules (e.g. system/hardware.nix) set `nixpkgs.config`. Let each node
  # own its nixpkgs config instead of the driver's read-only pkgs — this
  # resolves the `nixpkgs.config` conflict and builds from the project's own
  # nixpkgs (same revision as production).
  node.pkgsReadOnly = false;

  # Single node: the global node.specialArgs is sufficient.
  node.specialArgs = nodeDef.specialArgs;

  nodes.${host} = {
    imports =
      nodeDef.modules
      ++ [
        ./test-tuning.nix
        testModule
      ]
      ++ lib.optional lan lanModule;

    # VM sizing lives here (qemu-vm-only options); test-tuning stays generic.
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;
    };
  };
}
