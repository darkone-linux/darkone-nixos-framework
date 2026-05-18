# Pre-configured dnsmasq for local gateway / router.
#
# :::note
# This configuration reads the `network` conf in `config.yaml` file.
# It is the essential functionality of the local gateway.
# :::

{
  lib,
  config,
  network,
  zone,
  ...
}:
let
  cfg = config.darkone.service.dnsmasq;
  wanInterface = zone.gateway.wan.interface;
  lanInterface = "lan0"; # bridge for internal interfaces
  lanIpRange = zone.networkIp + "/" + toString zone.prefixLength;
  hasAdguardHome = config.darkone.service.adguardhome.enable;
  isTailscaleSubnet = network.coordination.enable && config.services.tailscale.enable;
in
{
  options = {
    darkone.service.dnsmasq.enable = lib.mkEnableOption "Enable local dnsmasq service";
  };

  config = lib.mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Networking: lan0 bridge, nat, gw interfaces, firewall
    #--------------------------------------------------------------------------

    networking = {

      # No IPv6 for the moment
      enableIPv6 = false;

      # Local domain
      inherit (zone) domain;

      # Probably useless with headscale magicdns?
      search = [
        zone.domain
        "tailnet.internal"
      ];

      # We need a bridge for dnsmasq settings (lan0)
      bridges.${lanInterface}.interfaces = zone.gateway.lan.interfaces;

      # Internet sharing / nat
      nat = {
        enable = true;
        externalInterface = zone.gateway.wan.interface;
        internalIPs = [ lanIpRange ];
        internalInterfaces = [ lanInterface ];
      };

      # DHCP Clients
      useDHCP = false;
      useNetworkd = true;
      interfaces = {
        ${wanInterface}.useDHCP = true;
        ${lanInterface} = {
          useDHCP = false;
          ipv4.addresses = [
            {
              address = zone.gateway.lan.ip;
              inherit (zone) prefixLength;
            }
          ];
        };
      };

      # Firewall
      # 53 -> DNS
      # 67, 68 -> DHCP
      # 80 -> homepage / caddy
      # 8501 -> packages proxy (ncps)
      firewall = {
        enable = true;
        allowPing = lib.mkDefault true;
        interfaces.${lanInterface} = {
          allowedTCPPorts = [
            22
            53
          ]
          ++ lib.optional config.services.caddy.enable 80
          ++ lib.optional config.darkone.service.ncps.enable 8501;
          allowedUDPPorts = [
            53
            67
            68
          ];
        };

        # No access from internet
        interfaces.${wanInterface} = {
          allowedTCPPorts = [ ];
          allowedUDPPorts = [ ];
        };
        extraCommands = ''
          # No ping on wan interface
          iptables -A nixos-fw -i ${wanInterface} -p icmp --icmp-type echo-request -j DROP
        '';
        extraStopCommands = ''
          # Extra rules cleans
          iptables -D nixos-fw -i ${wanInterface} -p icmp --icmp-type echo-request -j DROP 2>/dev/null || true
        '';
      };

      # /etc/hosts + avoid additional loopback entries in 127.0.0.2
      hosts = {
        "127.0.0.2" = lib.mkForce [ ];
      };
    };

    #--------------------------------------------------------------------------
    # Services parameters
    #--------------------------------------------------------------------------

    # lan0 bridge must be created before starting dnsmasq
    systemd.services.dnsmasq = {
      wants = [
        "network-online.target"
        "sys-subsystem-net-devices-${lanInterface}.device"
      ];
      after = [
        "network-online.target"
        "sys-subsystem-net-devices-${lanInterface}.device"
      ];
      bindsTo = [ "sys-subsystem-net-devices-${lanInterface}.device" ];
    };

    # Required for network-online.target
    systemd.network.wait-online = {
      enable = true;
      anyInterface = true;
      timeout = 30;
    };

    # No resolved service
    services.resolved.enable = false;

    #--------------------------------------------------------------------------
    # Dnsmasq
    #--------------------------------------------------------------------------

    services.dnsmasq = {
      enable = true;
      alwaysKeepRunning = true;

      settings = lib.mkMerge [
        {

          # Local domain appended to DNS names of DHCP-assigned machines
          # -> Does not allow managing machines from other zones with tailnet!
          domain = lib.mkIf (!isTailscaleSubnet) zone.domain;

          interface = [
            lanInterface
            (lib.mkIf isTailscaleSubnet config.services.tailscale.interfaceName)
          ];

          # Unlike --bind-interfaces, binds to lan0 first,
          # then to tailscale0 once it becomes available.
          bind-dynamic = true; # Avoid conflicts with tailscale

          # https://man.archlinux.org/man/dnsmasq.8.fr#K,
          dhcp-authoritative = true;
          no-dhcp-interface = "lo";

          # Use headscale DNS if we are a tailnet subnet (null)
          #server = lib.optional isTailscaleSubnet "100.100.100.100";
          server = [
            "/${zone.domain}/#" # Do not forward my zone (-> loop: zone -> tailscale -> zone)
          ]

          # Never forward the headscale domain, reply NXDOMAIN immediately for AAAA
          # -> Otherwise the domain would resolve to an internal tailnet ipv4 and tailscale
          #    would be unable to find headscale. Alternative: filter-aaaa
          ++ (lib.optional isTailscaleSubnet "/${network.coordination.domain}.${network.domain}/")

          # Other zones (not current, not www)
          # -> TODO: remove? Internal zone addresses are already generated by the generator,
          #          this loop adds tailnet ipv4 addresses, not useful...
          # ++ (lib.mapAttrsToList (_: z: "/${z.domain}/${z.gateway.vpn.ipv4}") (
          #   lib.filterAttrs (
          #     n: z: (n != "www" && n != zone.name && lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z)
          #   ) network.zones
          # ))

          # Other external DNS
          ++ lib.optionals hasAdguardHome [
            "94.140.14.14"
            "94.140.15.15"
          ]
          ++ [
            "1.1.1.1"
            "9.9.9.9"
          ];

          # Queries for these domains are only answered from /etc/hosts or DHCP.
          # They are not forwarded to upstream servers.
          local = "/${zone.domain}/";

          # Register the IP of gateway
          #address = [ "/${zone.gateway.hostname}.${zone.domain}/${zone.gateway.lan.ip}" ];

          # Use a different DNS port if adguardhome is enabled.
          port = if hasAdguardHome then 5353 else 53;

          # Prefer /etc/hosts ips matching the local network.
          localise-queries = true;

          # local-name -> local-name.zone.domain.tld
          expand-hosts = true;

          # Accept DNS queries only from hosts whose address is on a local subnet.
          # Only communicate with machines on our network.
          local-service = true;

          # Log results of all DNS queries
          log-queries = lib.mkDefault true;

          # Don't forward requests for the local address ranges (10.x.x.x) to upstream nameservers.
          # Fake reverse lookup for private networks. All reverse DNS queries for
          # private IP addresses (e.g. 192.168.x.x, etc.) not found in /etc/hosts or
          # the DHCP leases file get a "no such domain" response
          # instead of being forwarded to upstream nameservers.
          bogus-priv = true;

          # Don't forward requests without dots or domain parts to upstream nameservers.
          # Tell Dnsmasq to never forward A or AAAA queries for simple names,
          # i.e. names without dots or domain parts.
          # TODO: decide what to do for simple names from other zones.
          domain-needed = true;

          # Main dhcp options + headscale return route
          # https://tailscale.com/kb/1019/subnets#disable-snat
          dhcp-option = [
            "option:netmask,255.255.0.0"
            "option:router,${zone.gateway.lan.ip}"
            "option:dns-server,${zone.gateway.lan.ip}"

            # Do not send a domain name / search with tailnet!
            # -> Does not allow managing machines from other zones with tailnet!
            (lib.mkIf (!isTailscaleSubnet) "option:domain-name,${zone.domain}")
            (lib.mkIf (!isTailscaleSubnet) "option:domain-search,${zone.domain}")

            # For the 100.64.x.x network, use the local gateway... (not working)
            #(lib.mkIf isTailscaleSubnet "121,100.64.0.0/10,${zone.gateway.lan.ip}")
          ];

          # Default: do not read /etc/resolv.conf, but headscale and adguardhome set it to false.
          # Do not read /etc/resolv.conf. Only get upstream nameserver addresses
          # from the command line or Dnsmasq configuration file.
          no-resolv = lib.mkDefault false;

          # Force dnsmasq to include the real client IP in upstream DNS queries.
          # Useful if adguardhome is behind dnsmasq, which is no longer the case here.
          #edns-packet-max = 1232;
          #add-subnet = "32,128";
        }

        # Generated configuration in var/generated/network.nix
        # -> dhcp-host + dhcp-range + address
        zone.extraDnsmasqSettings
      ];
    };
  };
}
