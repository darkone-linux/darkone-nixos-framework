# Full-configured AdGuard Home for local gateway / router.
#
# :::note
# This configuration reads the `network` conf in `config.yaml` file.
# It uses the [DNF dnsmasq module](/ref/modules/#-darkoneservicednsmasq) as upstream DNS and DHCP.
# :::

{
  lib,
  dnfLib,
  config,
  network,
  zone,
  host,
  ...
}:
let
  cfg = config.darkone.service.adguardhome;
  agh = config.services.adguardhome;
  params = dnfLib.extractServiceParams host network "adguardhome" {
    title = "AdGuardHome";
    description = "Ad and tracker blocker";
    icon = "adguard-home";
  };

  # TODO: find dnsmasq IP and port if not in the same machine, or consider
  # ADH and DNSMASQ are on the same host.
  dnsmasqAddr = "127.0.0.1:" + (toString config.services.dnsmasq.settings.port);
in
{
  options = {
    darkone.service.adguardhome.enable = lib.mkEnableOption "Enable local adguardhome service";
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.adguardhome = {
        inherit params;
        proxy.servicePort = agh.port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.adguardhome.enable = true;
      };

      #------------------------------------------------------------------------
      # dnsmasq updates
      #------------------------------------------------------------------------

      # services.dnsmasq.settings = lib.mkIf hasDnsmasq {
      #   no-resolv = false;
      #   server = [
      #     "94.140.14.14"
      #     "94.140.15.15"
      #   ]
      #   ++ config.services.adguardhome.settings.dns.fallback_dns;
      # };

      #------------------------------------------------------------------------
      # adguardhome Service
      #------------------------------------------------------------------------

      # TODO: clients from config.yaml + update password
      services.adguardhome = {
        enable = true;

        # DHCP is managed by dnsmasq
        allowDHCP = false;

        # Web interface default host + port (target for reverse proxy)
        port = 3083;
        host = params.ip;

        # Allow changes made on the AdGuard Home web interface to persist between service restarts.
        mutableSettings = true;

        settings = {
          http = {
            address = "${toString agh.host}:${toString agh.port}";
            session_ttl = "720h";
          };
          users = [
            {
              name = "admin";
              password = network.default.password-hash;
            }
          ];
          auth_attempts = 5;
          block_auth_min = 1;
          language = zone.lang;

          # adguardhome is a dnsmasq upstream
          dns = {
            port = 53;
            bind_hosts = [ "0.0.0.0" ];

            # DOMAIN ROUTING
            # 1. Noms simples → dnsmasq
            # 2. Domaines locaux → dnsmasq
            # 3. Tout le reste → dns de ADH
            upstream_dns = [

              # Unqualified names (hosts, services)
              # https://github.com/AdguardTeam/Adguardhome/wiki/Configuration#specifying-upstreams-for-domains
              ("[//]" + dnsmasqAddr)

              # Local names
              ("[/" + network.domain + "/]" + dnsmasqAddr)

              # Reverse DNS upstream (utile ?)
              #("[/10.in-addr.arpa/]" + dnsmasqAddr)
              #(lib.mkIf hasHcs "[/100.in-addr.arpa/]100.100.100.100")

              "94.140.14.14"
              "94.140.15.15"
              "https://dns.adguard-dns.com/dns-query"
            ];
            bootstrap_dns = [
              "9.9.9.10"
              "149.112.112.10"
              "2620:fe::10"
              "2620:fe::fe:10"
            ];
            fallback_dns = [
              "8.8.8.8"
              "8.8.4.4"
              "1.1.1.1"
            ];

            # N'ajoute pas de suffixe à mes noms
            local_domain_name = "";

            # List of upstream dns for local queries (+reverse?)
            local_ptr_upstreams = [ dnsmasqAddr ];

            # Forward to dnsmasq if needed!
            # IMPORTANT: do not activate with headscale (DNS infinite loop)
            use_private_ptr_resolvers = false;

            # Cache must be disabled to not disturb dnsmasq configuration changes
            cache_enabled = false;

            # Retrieve client ips from dnsmasq (Active EDNS Client Subnet)
            # Note: deactivated -> dnsmasq forward external queries to adguard
            #ecs = true;
          };
          tls.enable = false;
          filtering = {
            blocking_mode = "default";
            protection_enabled = true;
            filtering_enabled = true;
            parental_enabled = false;
            safe_search = {
              enabled = true;
            };
          };

          # The following notation uses map
          # to not have to manually create {enabled = true; url = "";} for every filter
          # This is, however, fully optional
          filters =
            map
              (url: {
                enabled = true;
                inherit url;
              })
              [
                "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"
                "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"
                "https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt"
              ];
          user_rules = [
            "! Youtube kids"
            "@@||youtubekids.com^"
            "@@||ytimg.com^"
            "@@||googlevideo.com^"
          ];
          dhcp.enable = false;
        };
      };
    })
  ];
}
