# DNF — zone gateway uplinks: primary WAN + backup links.
#
# Pure data for `mixin/host/gateway.nix`: which interface carries which
# networkd file and route metric, the conflicts to assert, and the
# wpa_supplicant networks rendered by a sops template.
#
# :::note[Failover by route metric]
# Lowest metric wins the default route. A lost link or lease drops its route
# (kernel failover). `dnf-uplink-monitor` adds `uplinkPenalty` to a link
# without Internet, `uplinkProbation` to one back from an outage until it
# proves itself. Tiers: healthy < on probation < dead; order kept within one.
# :::
#
# :::note[Standby wifi]
# A wifi backup keeps its radio off (rfkill) until no preferred link reaches
# the Internet: a hotspot is metered and drains a phone. Ethernet stays up.
# :::

{ lib }:
let
  inherit (lib)
    concatMapStringsSep
    filter
    groupBy
    head
    length
    mapAttrsToList
    sort
    unique
    ;

  # Attrset of links -> list, each link carrying its own name.
  linkList = backupLinks: mapAttrsToList (name: link: link // { inherit name; }) backupLinks;

  # Stable order: preferred first, name as tie-breaker.
  byPriority = sort (a: b: a.priority < b.priority || (a.priority == b.priority && a.name < b.name));
in
rec {

  # Route metrics. Backups stay above the primary whatever their priority;
  # probation lifts a link above every healthy one, the penalty above every
  # link on probation.
  primaryMetric = 100;
  backupMetric = priority: 200 + 10 * priority;
  uplinkProbation = 10000;
  uplinkPenalty = 20000;

  # networkd file stems. `40-<iface>` is the name NixOS derives from
  # `networking.interfaces.<iface>`; the penalty drop-in must target it.
  primaryNetworkFile = wanInterface: "40-${wanInterface}";
  backupNetworkFile = iface: "45-dnf-backup-${iface}";

  # sops key of a wifi link field (`ssid` or `psk`).
  backupLinkSecret = name: field: "backup-link/${name}/${field}";

  # One entry per uplink interface, primary first, then backups by metric.
  # Several wifi links may share one radio: wpa_supplicant picks among them,
  # the interface keeps the metric of its preferred link. `standby`: radio
  # held off by the monitor while a preferred link is healthy.
  #
  # Usage:
  #   mkUplinks { wanInterface = "eno0"; backupLinks = { phone = { type = "wifi"; interface = "wlp4s0"; priority = 10; }; }; }
  #   => [ { interface = "eno0"; role = "primary"; metric = 100; standby = false; ... }
  #        { interface = "wlp4s0"; role = "backup"; metric = 300; standby = true; links = [ "phone" ]; ... } ]
  mkUplinks =
    { wanInterface, backupLinks }:
    let
      backups = mapAttrsToList (
        iface: links:
        let
          sorted = byPriority links;
        in
        {
          interface = iface;
          inherit (head sorted) type;
          role = "backup";
          networkFile = backupNetworkFile iface;
          metric = backupMetric (head sorted).priority;
          standby = (head sorted).type == "wifi";
          links = map (l: l.name) sorted;
        }
      ) (groupBy (l: l.interface) (linkList backupLinks));
    in
    [
      {
        interface = wanInterface;
        type = "ethernet";
        role = "primary";
        networkFile = primaryNetworkFile wanInterface;
        metric = primaryMetric;
        standby = false;
        links = [ ];
      }
    ]
    ++ sort (a: b: a.metric < b.metric || (a.metric == b.metric && a.interface < b.interface)) backups;

  # Human-readable violations (empty == valid). `reservedInterfaces` maps an
  # interface already in use to its role, e.g. `{ eno1 = "zone LAN port"; }`.
  uplinkConflicts =
    {
      wanInterface,
      backupLinks,
      reservedInterfaces ? { },
    }:
    let
      links = linkList backupLinks;

      # Name feeds a sops path, a unit-visible label and a wpa comment.
      badNames = map (l: "backup link \"${l.name}\": name must match [a-z][a-z0-9-]*") (
        filter (l: builtins.match "[a-z][a-z0-9-]*" l.name == null) links
      );

      onWan = map (l: "backup link \"${l.name}\": ${l.interface} is the primary WAN") (
        filter (l: l.interface == wanInterface) links
      );

      reserved = map (
        l: "backup link \"${l.name}\": ${l.interface} is already the ${reservedInterfaces.${l.interface}}"
      ) (filter (l: reservedInterfaces ? ${l.interface}) links);

      # A radio may carry several SSIDs (one joined at a time); a wired port
      # has exactly one peer.
      shared = lib.concatLists (
        mapAttrsToList (
          iface: ls:
          let
            types = unique (map (l: l.type) ls);
            names = concatMapStringsSep ", " (l: l.name) ls;
          in
          if length types > 1 then
            [ "backup links ${names}: ${iface} cannot be both ethernet and wifi" ]
          else if head types == "ethernet" && length ls > 1 then
            [ "backup links ${names}: ethernet ${iface} carries a single link" ]
          else
            [ ]
        ) (groupBy (l: l.interface) links)
      );
    in
    badNames ++ onWan ++ reserved ++ shared;

  # wpa_supplicant `network={}` blocks of the wifi links, for a file loaded
  # with `-I`. `placeholder name field` returns the sops placeholder of a
  # secret, so SSID and passphrase only exist in the rendered template.
  # WPA2/WPA3-transition: PSK or SAE, PMF optional.
  mkWpaNetworks =
    { backupLinks, placeholder }:
    concatMapStringsSep "\n" (l: ''
      # backup link: ${l.name}
      network={
        ssid="${placeholder l.name "ssid"}"
        psk="${placeholder l.name "psk"}"
        key_mgmt=WPA-PSK SAE
        ieee80211w=1
        priority=${toString (100 - l.priority)}
      }
    '') (byPriority (filter (l: l.type == "wifi") (linkList backupLinks)));
}
