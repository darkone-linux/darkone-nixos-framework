# DNF — headscale ACL policy derived from the network topology
#
# Builds the tailnet policy (groups, tagOwners, hosts, autoApprovers, acls)
# from the generated hosts, users and zones. Pure and side-effect free:
# `service/headscale.nix` serializes the result and checks it at build time.

{ lib, topology }:
let
  inherit (lib)
    attrNames
    elem
    filter
    filterAttrs
    genAttrs
    hasAttr
    hasPrefix
    listToAttrs
    mapAttrs
    mapAttrs'
    nameValuePair
    optional
    removePrefix
    ;

  hcsTag = "tag:hcs";
  adminTag = "tag:admin";

  # One tag per zone gateway: route auto-approval then cannot hand a gateway
  # the subnet of another zone.
  gatewayTag = zoneName: "tag:gw-${zoneName}";

  # `profile` is a path, its basename names the home-manager profile.
  adminProfiles = [
    "admin"
    "nix-admin"
  ];
  isAdminUser = user: elem (baseNameOf (user.profile or "")) adminProfiles;
  userZones = user: map (removePrefix "zone-") (filter (hasPrefix "zone-") (user.groups or [ ]));

  # Host `groups` lists who logs in, never the free-form `tags`: a label must
  # not grant network rights. Admins also log in on gateways and the HCS,
  # which stay infrastructure.
  isAdminStation =
    host: zone: network:
    elem "admin" (host.groups or [ ])
    && !(topology.isHcs host zone network)
    && !(topology.isGateway host zone);

  # The global zone has no subnet to route.
  localZones = network: filterAttrs (_: topology.inLocalZone) network.zones;

  zoneCidr = zone: "${zone.networkIp}/${toString zone.prefixLength}";
  zoneAlias = zoneName: "zone-${zoneName}";
  userRef = login: "${login}@";

  accept = src: dst: {
    action = "accept";
    inherit src dst;
  };
in
{

  # Tags of a tailnet machine, as passed to `--tags`. Empty for a host with no
  # tailnet role: it is reached through its zone subnet.
  tailnetNodeTags =
    { host, network }:
    let
      zone = network.zones.${host.zone} or { name = host.zone; };
    in
    optional (topology.isHcs host zone network) hcsTag
    ++ optional (topology.inLocalZone zone && topology.isGateway host zone) (gatewayTag zone.name)
    ++ optional (isAdminStation host zone network) adminTag;

  # Logins allowed to join the tailnet: an admin profile, or a zone to reach.
  tailnetUsers = users: attrNames (filterAttrs (_: u: isAdminUser u || userZones u != [ ]) users);

  # Tailnet policy, default deny. `enforce = false` keeps every identity but
  # allows all traffic: nodes get tagged before the switch without cutting the
  # admin path. `adminDevices`: name -> tailnet IPv4 granted SSH everywhere.
  mkHeadscalePolicy =
    {
      network,
      hosts,
      users,
      enforce ? true,
      adminDevices ? { },
      exitNodeSources ? [ ],
      extraAcls ? [ ],
      extraHosts ? { },
    }:
    let
      zones = localZones network;
      zoneNames = attrNames zones;
      zoneAliases = map zoneAlias zoneNames;
      gatewayTags = map gatewayTag zoneNames;
      allTags = [ hcsTag ] ++ gatewayTags ++ [ adminTag ];
      adminHosts = filter (
        h: hasAttr h.zone zones && (h.ip or "") != "" && isAdminStation h zones.${h.zone} network
      ) hosts;

      # Empty groups are dropped: a rule naming an undefined group fails the
      # whole policy.
      zoneUsers = zoneName: attrNames (filterAttrs (_: u: elem zoneName (userZones u)) users);
      groups = filterAttrs (_: members: members != [ ]) (
        {
          "group:admins" = map userRef (attrNames (filterAttrs (_: isAdminUser) users));
        }
        // listToAttrs (map (z: nameValuePair "group:zone-${z}" (map userRef (zoneUsers z))) zoneNames)
      );
      hasGroup = name: hasAttr name groups;

      toEverywhere = ports: map (target: "${target}:${ports}") (allTags ++ zoneAliases);

      enforcedAcls = [

        # Machines and zone LANs reach each other on every port, for now.
        (accept (allTags ++ zoneAliases) (toEverywhere "*"))

        # Personal devices: internal DNS and global services on the HCS.
        (accept [ "autogroup:member" ] [ "${hcsTag}:53,443" ])
      ]
      ++ optional (hasGroup "group:admins") (
        accept [ "group:admins" ] (map (tag: "${tag}:443") gatewayTags)
      )
      ++ map (z: accept [ "group:zone-${z}" ] [ "${gatewayTag z}:443" ]) (
        filter (z: hasGroup "group:zone-${z}") zoneNames
      )
      ++ [
        (accept [ "autogroup:member" ] [ "autogroup:self:*" ])

        # SSH follows the station, not the user.
        (accept ([ adminTag ] ++ map (h: h.hostname) adminHosts ++ attrNames adminDevices) (
          toEverywhere "22"
        ))
      ]
      ++ optional (exitNodeSources != [ ]) (accept exitNodeSources [ "autogroup:internet:*" ])
      ++ extraAcls;

      # Since headscale 0.29 `*` covers tailnet addresses only: zone subnets
      # must be named, or the migration cuts inter-zone traffic.
      openAcls = [
        (accept ([ "*" ] ++ zoneAliases) (
          [ "*:*" ] ++ map (alias: "${alias}:*") zoneAliases ++ [ "autogroup:internet:*" ]
        ))
      ];
    in
    {
      inherit groups;
      tagOwners = genAttrs allTags (_: optional (hasGroup "group:admins") "group:admins");
      hosts =
        mapAttrs' (z: zone: nameValuePair (zoneAlias z) (zoneCidr zone)) zones
        // listToAttrs (map (h: nameValuePair h.hostname "${h.ip}/32") adminHosts)
        // mapAttrs (_: ip: "${ip}/32") adminDevices
        // extraHosts;
      autoApprovers = {
        routes = mapAttrs' (z: zone: nameValuePair (zoneCidr zone) [ (gatewayTag z) ]) zones;
        exitNode = [ hcsTag ];
      };
      acls = if enforce then enforcedAcls else openAcls;
    };
}
