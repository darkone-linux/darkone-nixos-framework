# L3 — DNF zone ↔ test-driver VLAN mapping.
#
# :::tip
# `runNixOSTest` uses integer VLAN ids on `virtualisation.vlans`; each id is
# a virtual L2 segment, and nodes sharing an id can reach each other on
# `eth<i>` (i = order of declaration). A gateway sits on its LAN VLAN + the
# shared WAN VLAN so it can simultaneously route for its zone and reach the
# outside.
# :::
#
# Conventions:
#   - one VLAN per DNF zone (z1 → 1, z2 → 2, ...)
#   - VLAN 9 is the shared "WAN" segment carried only by gateways
#   - host.zone is the bare zone name ("z1"), as emitted by the generator
#     in `var/generated/hosts.nix`
#
# Aim: use.

{ ... }:
let
  zoneVlans = {
    z1 = 1;
    z2 = 2;
    z3 = 3;
  };
  wanVlan = 9;
in
{
  inherit zoneVlans wanVlan;

  # Per-node module fragment: pins `virtualisation.vlans` to the zone's
  # VLAN, prepending the WAN VLAN for gateways so they get a second NIC.
  # Falls back to VLAN 1 for hosts whose zone is not registered here.
  forHost =
    host:
    let
      lanVlan = zoneVlans.${host.zone} or 1;
      isGateway = host.profile == "gateway";
    in
    {
      virtualisation.vlans =
        if isGateway then
          [
            wanVlan
            lanVlan
          ]
        else
          [ lanVlan ];
    };
}
