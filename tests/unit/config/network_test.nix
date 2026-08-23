# Tests for config/network.nix (framework-wide port registry)
# Run with: nix-unit --flake .#libTests
{ dnfLib, lib }:
let
  inherit (dnfLib) checkSchema;

  ports = (import ../../../config/network.nix).ports;

  # Named DNF ports (everything but the `reserved` denylist).
  named = builtins.removeAttrs ports [ "reserved" ];
  reserved = ports.reserved;

  # Kernel ephemeral range (`net.ipv4.ip_local_port_range` default): a fixed
  # port picked in there can be stolen by any outgoing connection of a
  # co-hosted service, so DNF-owned ports must stay out of it. Not enforced on
  # `reserved`, whose values are upstream defaults DNF cannot choose.
  ephemeral = {
    from = 32768;
    to = 60999;
  };

  # Shape of the named map: alphanumeric keys, values are unique ints in the
  # 1024..65535 range. Any new `ports.<key>` is validated by this alone.
  namedSchema = {
    type = "attrs";
    key.regex = "[a-zA-Z0-9]+";
    value = {
      type = "int";
      min = 1024;
      max = 65535;
      unique = true;
    };
  };

  # Reserved entries must also be ints inside the valid port range.
  reservedOutOfRange = lib.filter (p: !(builtins.isInt p) || p < 1024 || p > 65535) reserved;

  #--------------------------------------------------------------------------
  # Ranges
  #--------------------------------------------------------------------------
  # A range is declared by two keys, `<name>Start` and `<name>End`: the service
  # owns every port in between, so the registry must treat it as an interval
  # and not as the two isolated values a naive uniqueness check would see.

  boundKeys = lib.filter (k: lib.hasSuffix "Start" k || lib.hasSuffix "End" k) (
    builtins.attrNames named
  );

  # `livekitRtcUdpStart` -> `livekitRtcUdp`.
  rangeNames = lib.unique (map (k: lib.removeSuffix "End" (lib.removeSuffix "Start" k)) boundKeys);

  hasBothBounds = n: named ? "${n}Start" && named ? "${n}End";

  # A lone bound is always a mistake: either its twin was forgotten, or a plain
  # port was misnamed and would silently escape the interval checks below.
  incompleteRanges = lib.filter (n: !(hasBothBounds n)) rangeNames;

  # Empty or inverted ranges open a firewall hole nothing listens on.
  invertedRanges = lib.filter (n: hasBothBounds n && named."${n}Start" > named."${n}End") rangeNames;

  #--------------------------------------------------------------------------
  # Occupancy
  #--------------------------------------------------------------------------
  # Everything the registry knows about, as labelled intervals: a plain port is
  # a one-port interval, a range spans its bounds. Collision detection is then
  # a single rule for both kinds.

  scalars = builtins.removeAttrs named boundKeys;

  intervals =
    lib.mapAttrsToList (k: v: {
      label = k;
      from = v;
      to = v;
      owned = true;
    }) scalars
    ++ map (p: {
      label = "reserved:${toString p}";
      from = p;
      to = p;
      owned = false;
    }) reserved
    ++ map (n: {
      label = "${n}Start..End";
      from = named."${n}Start";
      to = named."${n}End";
      owned = true;
    }) (lib.filter hasBothBounds rangeNames);

  # Pairwise overlap, each pair looked at once (`b` after `a`). ~50 entries:
  # the quadratic walk stays free, and reports which two entries clash.
  indexed = lib.imap0 (i: v: v // { index = i; }) intervals;
  overlaps = lib.concatMap (
    a:
    map (b: "${a.label} <-> ${b.label}") (
      lib.filter (b: b.index > a.index && a.from <= b.to && b.from <= a.to) indexed
    )
  ) indexed;

  # DNF-owned entries (plain ports and ranges alike) crossing the ephemeral
  # range.
  inEphemeral = map (i: i.label) (
    lib.filter (i: i.owned && i.from <= ephemeral.to && ephemeral.from <= i.to) intervals
  );
in
{

  # Named ports: shape, bounds and uniqueness among themselves.
  testNamedPortsValid = {
    expr = checkSchema namedSchema named;
    expected = [ ];
  };

  # Reserved ports: ints in range.
  testReservedInRange = {
    expr = reservedOutOfRange;
    expected = [ ];
  };

  # Every `<name>Start` has its `<name>End` (and vice versa).
  testRangesComplete = {
    expr = incompleteRanges;
    expected = [ ];
  };

  # Range bounds are ordered.
  testRangesOrdered = {
    expr = invertedRanges;
    expected = [ ];
  };

  # The whole point of the registry: nothing may sit on a port another entry
  # already owns — a range covering every port between its bounds.
  testNoPortCollision = {
    expr = overlaps;
    expected = [ ];
  };

  # DNF-owned ports stay out of the kernel ephemeral range.
  testNoEphemeralPort = {
    expr = inEphemeral;
    expected = [ ];
  };
}
