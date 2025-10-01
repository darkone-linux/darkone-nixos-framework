# Pre-configured adguard-home for local gateway / router.
#
# :::note
# This configuration reads the `network` conf in `config.yaml` file.
# :::

{
  lib,
  config,
  host,
  network,
  ...
}:
let
  cfg = config.darkone.service.adguardhome;
  agh = config.services.adguardhome;
  dnsmasqAddr = "127.0.0.1:" + (toString config.services.dnsmasq.settings.port);
in
{
  options = {
    darkone.service.adguardhome.enable = lib.mkEnableOption "Enable local adguardhome service";
    darkone.service.adguardhome.domainName = lib.mkOption {
      type = lib.types.str;
      default = "adguardhome";
      description = "Domain name for Adguard Home, registered in nginx & hosts";
    };
  };

  config = lib.mkIf cfg.enable {

    # Virtualhost for adguardhome
    services.nginx = {
      enable = lib.mkForce true;
      virtualHosts.${cfg.domainName} = {
        extraConfig = ''
          client_max_body_size 512M;
        '';
        locations."/".proxyPass = "http://127.0.0.1:${toString agh.port}";
      };
    };

    # Add adguardhome domain to /etc/hosts
    networking.hosts."${host.ip}" = lib.mkIf config.services.adguardhome.enable [ "${cfg.domainName}" ];

    # Add adguardhome in Administration section of homepage
    darkone.service.homepage.adminServices = [
      {
        "AdGuard Home" = {
          description = "Bloqueur de publicités et de traqueurs";
          href = "http://adguardhome";
          icon = "sh-adguard-home";
        };
      }
    ];

    # adguardhome Service
    # TODO: clients from config.yaml + update password
    services.adguardhome = {
      enable = true;

      # DHCP is managed by dnsmasq
      allowDHCP = false;

      # Web interface default host + port (target for nginx)
      port = 3083;
      host = "127.0.0.1";

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
        language = lib.toLower (builtins.substring 0 2 network.locale);

        # adguardhome is a dnsmasq upstream
        dns = {
          port = 53;
          bind_hosts = [ "0.0.0.0" ];
          upstream_dns = [

            # Local dns server for internal queries
            ("[//]" + dnsmasqAddr)
            ("[/" + network.domain + "/]" + dnsmasqAddr)

            # Reverse DNS upstream
            ("[/in-addr.arpa/]" + dnsmasqAddr)

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

          # List of upstream dns for local queries (+reverse?)
          local_ptr_upstreams = [ dnsmasqAddr ];

          # Forward to dnsmasq if needed!
          use_private_ptr_resolvers = true;

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
  };
}
