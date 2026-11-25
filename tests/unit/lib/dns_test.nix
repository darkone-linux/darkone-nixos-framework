# Tests for dnf/lib/dns.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib, lib }:
let
  inherit (dnfLib) publicResolvers;
  pair = [
    "cloudflare"
    "adguard"
  ];
in
{

  # ----- publicResolvers: catalog shape -----

  # Every consumer form needs both families and the certificate name: a missing
  # field would only fail on the host that derives it.
  testEveryEntryIsComplete = {
    expr = lib.all (r: r.ipv4 != [ ] && r.ipv6 != [ ] && r.tlsName != "") (
      lib.attrValues publicResolvers
    );
    expected = true;
  };

  # An address listed twice would be one operator counted as two.
  testNoAddressIsShared = {
    expr =
      let
        all = lib.concatMap (r: r.ipv4 ++ r.ipv6) (lib.attrValues publicResolvers);
      in
      lib.length all == lib.length (lib.unique all);
    expected = true;
  };

  # ----- resolversOf: selection order -----

  # The option order is the preference order handed to every consumer.
  testKeepsSelectionOrder = {
    expr = map (r: r.tlsName) (
      dnfLib.resolversOf [
        "adguard"
        "quad9"
      ]
    );
    expected = [
      "unfiltered.adguard-dns.com"
      "dns.quad9.net"
    ];
  };

  # ----- mkUnboundForwardAddrs: DoT checked by name -----

  testUnboundForwardAddrs = {
    expr = dnfLib.mkUnboundForwardAddrs pair;
    expected = [
      "1.1.1.1#cloudflare-dns.com"
      "1.0.0.1#cloudflare-dns.com"
      "94.140.14.140#unfiltered.adguard-dns.com"
      "94.140.14.141#unfiltered.adguard-dns.com"
    ];
  };

  # ----- mkResolverAddrs: plain bootstrap, IPv4 first -----

  testResolverAddrsPutIpv4First = {
    expr = dnfLib.mkResolverAddrs pair;
    expected = [
      "1.1.1.1"
      "1.0.0.1"
      "94.140.14.140"
      "94.140.14.141"
      "2606:4700:4700::1111"
      "2606:4700:4700::1001"
      "2a10:50c0::1:ff"
      "2a10:50c0::2:ff"
    ];
  };

  # ----- mkResolverTlsUrls: DoT by IP, no bootstrap -----

  testResolverTlsUrls = {
    expr = dnfLib.mkResolverTlsUrls [ "quad9" ];
    expected = [
      "tls://9.9.9.9"
      "tls://149.112.112.112"
    ];
  };

  # ----- mkResolverPrimaryIpv4s: one plain fallback per operator -----

  testPrimaryIpv4PerOperator = {
    expr = dnfLib.mkResolverPrimaryIpv4s pair;
    expected = [
      "1.1.1.1"
      "94.140.14.140"
    ];
  };

  # Empty selection: empty forms, the module assertion reports it.
  testEmptySelection = {
    expr = dnfLib.mkUnboundForwardAddrs [ ];
    expected = [ ];
  };
}
