# A full-configured headscale service for HCS.

# TODO: works but can be simplified / optimized.
{
  lib,
  dnfLib,
  config,
  network,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.headscale;
  srv = config.services.headscale;
  defaultParams = {
    inherit (network.coordination) domain;
    description = "Headscale DNF service";
    ip = srv.address;
    global = true;
    noRobots = false;
  };
  hcsTailnetIpv4 = network.zones.www.gateway.vpn.ipv4;
  params = dnfLib.extractServiceParams host network "headscale" defaultParams;
in
{
  options = {
    darkone.service.headscale.enable = lib.mkEnableOption "Enable headscale DNF service";
    darkone.service.headscale.enableGRPC = lib.mkEnableOption "Open GRPC TCP port";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.headscale = {
        displayOnHomepage = false;
        inherit defaultParams;
        persist.dirs = [ "/var/lib/headscale" ];
        proxy.servicePort = srv.port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "headscale";

      #------------------------------------------------------------------------
      # Unbound (pivot DNS)
      #------------------------------------------------------------------------

      # Unbound is required by headscale
      systemd.services.headscale = {
        wants = [ "unbound.service" ];
        after = [ "unbound.service" ];
      };

      services.unbound = {
        enable = true;
        settings = {
          server = {
            interface = [
              "127.0.0.1"
              hcsTailnetIpv4
            ];
            access-control = [
              "127.0.0.1 allow"
              "100.64.0.0/10 allow"
            ];
            inherit (zone.unbound) local-data;
            harden-glue = true;
            harden-dnssec-stripped = true;
            use-caps-for-id = false;
            prefetch = true;
            edns-buffer-size = 1232;
            hide-identity = true;
            hide-version = true;
          };
          forward-zone =
            lib.mapAttrsToList
              (_: z: {
                name = "${z.domain}.";
                forward-addr = [ "${z.gateway.vpn.ipv4}" ];
              })
              (
                lib.filterAttrs (n: z: (lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z) && n != "www") network.zones
              )
            ++ [
              {
                name = ".";
                forward-addr = [
                  "9.9.9.9#dns.quad9.net"
                  "149.112.112.112#dns.quad9.net"
                ];
                forward-tls-upstream = true; # Protected DNS
              }
            ];

          # Syntax error
          # local-zone = "\"tailnet.internal.\" static";
        };
      };

      #------------------------------------------------------------------------
      # Headscale main configuration
      #------------------------------------------------------------------------

      # TODO: Derp relay, ACLs, OIDC
      services.headscale = {
        enable = true;
        settings = {

          # Public Headscale server URL
          server_url = "https://${params.fqdn}:443";

          # Configuration DNS
          dns = {

            # MagicDNS enabled (default)
            magic_dns = true;

            # Base domain for MagicDNS
            # -> Use an internal domain here to prevent names from
            #    leaking to the internet / external DNS. A name like vpn.mydomain.tld
            #    is not a good idea!
            base_domain = "tailnet.internal";

            # Force headscale DNS config over node local DNS
            override_local_dns = false;

            # ACLs (TODO)
            #acl_policy_path = "/var/lib/headscale/acls.json";

            # OIDC (for future integration with Authelia)
            # https://github.com/juanfont/headscale/blob/9c4c017eac2e81908d2ae7d8d777e143a13a1772/config-example.yaml#L329
            # oidc = {
            #   issuer = "https://auth.mydomain.tld";
            #   client_id = "headscale";
            #   client_secret_path = "/var/lib/headscale/oidc_secret";
            # };

            # DNS servers for clients (fallback only...)
            # -> We do not resolve external domains on headscale for now.
            nameservers = {
              global = [
                hcsTailnetIpv4
                # "1.1.1.1"
                # "1.0.0.1"
                # "2606:4700:4700::1111"
                # "2606:4700:4700::1001"
              ];

              # Tailscale clients address 100.100.100.100.
              # -> Everything under the network domain must be handled by HCS unbound DNS.
              split.${network.domain} = [ hcsTailnetIpv4 ];

              # Each zone suffix gets its own DNS server...
              # { "zone.domain.tld" = [ "100.64.x.x" ]; (...) };
              # NOTE: Headscale split-DNS only tells clients which DNS to query
              #        for which zone, it does not resolve or chain DNS itself.
              #        Unbound now serves as the pivot DNS server for zones.
              #        The previous split delegates main domain DNS handling to Unbound.
              # split = lib.concatMapAttrs (_: z: { "${z.domain}" = [ "${z.gateway.vpn.ipv4}" ]; }) (
              #   lib.filterAttrs (_: z: lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z) network.zones
              # );
            };

            # Search domains
            # -> No search through headscale for now.
            # zone1.domain.tld, zone2.domain.tld, etc.
            # With MagicDNS enabled, your tailnet base_domain is always the first search domain.
            # search_domains = [
            #   srv.settings.dns.base_domain
            # ]
            # ++ lib.attrsets.mapAttrsToList (_: z: z.domain) hcsClientZones;
            #search_domains = lib.attrsets.mapAttrsToList (_: z: z.domain) hcsClientZones;
            search_domains = [ "tailnet.internal" ];

            # See if we should put global services here (DOES NOT WORK - NO EFFECT)
            # To use for global services?
            # https://github.com/juanfont/headscale/blob/9c4c017eac2e81908d2ae7d8d777e143a13a1772/config-example.yaml#L312
            # extra_records = lib.attrsets.mapAttrsToList (_: z: {
            #   name = "${z.gateway.hostname}.${z.domain}";
            #   type = "A";
            #   value = "100.64.${z.ipPrefix}";
            # }) hcsClientZones;
          }; # dns

          # TODO: https://search.nixos.org/options?channel=unstable&query=services.headscale.settings.oidc
          #oidc = {};
        };
      };

      #--------------------------------------------------------------------------
      # Firewall
      #--------------------------------------------------------------------------

      # https://headscale.net/stable/setup/requirements/#ports-in-use
      networking.firewall = {

        # Open HTTP on all interfaces if not the gateway
        allowedTCPPorts = [
          80 # Caddy, let's encrypt
          443 # Tailscale clients, DERP server
          (lib.mkIf cfg.enableGRPC 50443) # gRPC
        ];

        allowedUDPPorts = [
          3478 # STUN, DERP server
        ];
      };
    })
  ];
}
