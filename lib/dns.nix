# Public DNS resolvers
#
# Catalog of the public operators the fleet may resolve Internet names with,
# and the forms each consumer needs. The selection lives in one option,
# `darkone.system.dns.publicResolvers` (`modules/system/dns.nix`); the HCS
# unbound, AdGuard Home and dnsmasq only derive from it, never list addresses.

{ lib }: rec {

  # One variant per operator. Every certificate carries its IPs as SANs
  # (checked 2026-11): `tls://<ip>` verifies without any bootstrap.
  publicResolvers = {
    quad9 = {
      ipv4 = [
        "9.9.9.9"
        "149.112.112.112"
      ];
      ipv6 = [
        "2620:fe::fe"
        "2620:fe::9"
      ];
      tlsName = "dns.quad9.net";
    };
    cloudflare = {
      ipv4 = [
        "1.1.1.1"
        "1.0.0.1"
      ];
      ipv6 = [
        "2606:4700:4700::1111"
        "2606:4700:4700::1001"
      ];
      tlsName = "cloudflare-dns.com";
    };

    # Unfiltered: zone filtering is AdGuard Home's job, not the resolver's.
    adguard = {
      ipv4 = [
        "94.140.14.140"
        "94.140.14.141"
      ];
      ipv6 = [
        "2a10:50c0::1:ff"
        "2a10:50c0::2:ff"
      ];
      tlsName = "unfiltered.adguard-dns.com";
    };
  };

  # Catalog entries of `names`, in the given order.
  #
  #   resolversOf [ "cloudflare" ]  => [ { ipv4 = [ … ]; ipv6 = [ … ]; tlsName = …; } ]
  resolversOf = map (name: publicResolvers.${name});

  # unbound `forward-addr`, with `forward-tls-upstream`: the name after `#`
  # is the one the certificate is checked against. IPv4 only.
  #
  #   mkUnboundForwardAddrs [ "cloudflare" ]  => [ "1.1.1.1#cloudflare-dns.com" "1.0.0.1#cloudflare-dns.com" ]
  mkUnboundForwardAddrs =
    names: lib.concatMap (r: map (ip: "${ip}#${r.tlsName}") r.ipv4) (resolversOf names);

  # Every address, all IPv4 first: plain DNS, for a bootstrap.
  #
  #   mkResolverAddrs [ "cloudflare" ]  => [ "1.1.1.1" "1.0.0.1" "2606:4700:4700::1111" "2606:4700:4700::1001" ]
  mkResolverAddrs =
    names:
    let
      resolvers = resolversOf names;
    in
    lib.concatMap (r: r.ipv4) resolvers ++ lib.concatMap (r: r.ipv6) resolvers;

  # DNS-over-TLS by IP: usable when no name resolves at all. IPv4 only.
  #
  #   mkResolverTlsUrls [ "cloudflare" ]  => [ "tls://1.1.1.1" "tls://1.0.0.1" ]
  mkResolverTlsUrls = names: map (ip: "tls://${ip}") (lib.concatMap (r: r.ipv4) (resolversOf names));

  # First IPv4 of each operator: one plain fallback per operator.
  #
  #   mkResolverPrimaryIpv4s [ "cloudflare" "adguard" ]  => [ "1.1.1.1" "94.140.14.140" ]
  mkResolverPrimaryIpv4s = names: map (r: lib.head r.ipv4) (resolversOf names);
}
