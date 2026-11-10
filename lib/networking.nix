# Networking helpers
#
# Pure helpers manipulating addresses and DNS naming.

{ lib }: rec {

  # Reverse-DNS prefix from the first two labels of a dotted string:
  # `"a.b.c.d"` -> `"b.a"`. Used to build the local PTR domain handed to
  # dnsmasq/AdGuard Home from the LAN network address.
  #
  # Usage:
  #   extractReversePrefix "192.168.1.0" => "168.192"
  extractReversePrefix =
    str:
    let
      parts = lib.splitString "." str;
      first = builtins.elemAt parts 0;
      second = builtins.elemAt parts 1;
    in
    "${second}.${first}";

  # MAC addresses the zone DHCP reserves for `ip`, read from the generated
  # `dhcp-host` entries (`mac,…,mac,ip`). `[ ]` when the address has no
  # reservation or the zone no DHCP (global zone).
  #
  # Usage:
  #   getReservedMacs zone "10.0.1.2" => [ "02:00:00:00:00:01" ]
  getReservedMacs =
    zone: ip:
    let
      entries = map (lib.splitString ",") (zone.extraDnsmasqSettings.dhcp-host or [ ]);
    in
    lib.concatMap lib.init (lib.filter (fields: lib.last fields == ip) entries);
}
