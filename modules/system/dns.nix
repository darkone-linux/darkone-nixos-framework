# Public DNS resolvers of the fleet.
#
# One option picks the public operators every DNF resolver sends Internet
# names to. Addresses come from the `dnfLib.publicResolvers` catalog
# (`lib/dns.nix`); each consumer derives its own form:
#
# | Consumer | Use | Form |
# |---|---|---|
# | unbound of the HCS (`headscale`) | forwarders | DoT, checked by name |
# | AdGuard Home (gateway) | `bootstrap_dns` | plain, IPv4 and IPv6 |
# | AdGuard Home (gateway) | `fallback_dns` | DoT by IP |
# | dnsmasq (gateway) | fallback servers | plain, first IPv4 of each |
#
# Out of this selection: AdGuard Home's filtering upstream (AdGuard DNS, a
# filtering policy) and the ICMP probes (`internetProbeTargets`).
#
# ```nix
# # usr/modules/dns.nix: back to Quad9 once it serves the country again
# { darkone.system.dns.publicResolvers = [ "quad9" "cloudflare" ]; }
# ```
#
# :::caution[Two operators, same on the HCS and the gateways]
# Asserted at evaluation: one operator refusing a whole country (Quad9, France,
# 2026-11-24) must not cut the fleet's DNS. Set it fleet-wide (`usr/modules/`),
# then deploy the HCS and every gateway.
# :::

{
  lib,
  config,
  dnfLib,
  ...
}:
let
  cfg = config.darkone.system.dns;
in
{
  options.darkone.system.dns.publicResolvers = lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames dnfLib.publicResolvers));
    default = [
      "cloudflare"
      "adguard"
    ];
    example = [
      "quad9"
      "cloudflare"
    ];
    description = "Public DNS operators (`dnfLib.publicResolvers`) the HCS unbound, AdGuard Home and dnsmasq send Internet names to.";
  };

  config.assertions = [
    {
      assertion = lib.length (lib.unique cfg.publicResolvers) >= 2;
      message = "darkone.system.dns.publicResolvers needs two distinct operators at least, got: ${toString cfg.publicResolvers}.";
    }
  ];
}
