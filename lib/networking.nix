# Networking helpers
#
# Pure helpers manipulating addresses and DNS naming.

{ lib }:
rec {

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
}
