# Pre-configured dnsmasq for local gateway / router.

{
  lib,
  config,
  network,
  ...
}:
let
  cfg = config.darkone.service.dnsmasq;
  inherit (network) domain;
  inherit (network) extraDnsmasqSettings;
  inherit (network) extraNetworking;
  inherit (network) gateway;
  wanInterface = network.gateway.interfaces.wan.interface;
  lanInterface = network.gateway.interfaces.lan.interface;
in
{
  options = {
    darkone.service.dnsmasq.enable = lib.mkEnableOption "Enable local dnsmasq service";
  };

  # TODO: IPv6 (cf. arthur gw conf)
  config = lib.mkIf cfg.enable {

    boot.kernel.sysctl = {
      # if you use ipv4, this is all you need
      "net.ipv4.conf.all.forwarding" = true;
    };

    networking = {

      # No IPv6 for the moment
      enableIPv6 = false;

      # Main configuration
      defaultGateway = {
        address = gateway.interfaces.wan.gateway;
        interface = wanInterface;
      };
      nameservers = [
        gateway.interfaces.wan.gateway
        "8.8.8.8"
        "8.8.4.4"
      ];

      # DHCP Clients
      useDHCP = false;
      interfaces = {
        ${wanInterface}.useDHCP = true;
        ${lanInterface} = {
          useDHCP = false;
          ipv4.addresses = [
            {
              address = gateway.interfaces.lan.ip;
              inherit (gateway.interfaces.lan) prefixLength;
            }
          ];
        };
      };

      # Firewall
      # 53 -> DNS
      # 67, 68 -> DHCP
      firewall = {
        enable = true;
        allowPing = true;
        interfaces.${lanInterface} = {
          allowedTCPPorts = [
            22
            53
          ];
          allowedUDPPorts = [
            53
            67
            68
          ];
        };
        extraCommands = ''
          # Set up SNAT on packets going from downstream to the wider internet
          iptables -t nat -A POSTROUTING -o ${wanInterface} -j MASQUERADE

          # Accept all connections from downstream. May not be necessary
          iptables -A INPUT -i ${lanInterface} -j ACCEPT
        '';
      };

      # /etc/hosts
      inherit (extraNetworking) hosts;
    };

    services.dnsmasq = {
      enable = true;
      alwaysKeepRunning = true;

      settings = {
        inherit domain;
        interface = lanInterface;
        bind-interfaces = true;
        dhcp-authoritative = true;
        no-dhcp-interface = "lo";

        # Prends dans /etc/hosts les ips qui matchent le réseau en priorité
        localise-queries = true;
        expand-hosts = true;

        # Accept DNS queries only from hosts whose address is on a local subnet
        local-service = true;

        # Log results of all DNS queries
        log-queries = true;

        # Don't forward requests for the local address ranges (192.168.x.x etc)
        # to upstream nameservers
        bogus-priv = true;

        # Don't forward requests without dots or domain parts to
        # upstream nameservers
        domain-needed = true;

        # Serveurs de nom
        server = config.networking.nameservers;
      } // extraDnsmasqSettings;
    };
  };
}
