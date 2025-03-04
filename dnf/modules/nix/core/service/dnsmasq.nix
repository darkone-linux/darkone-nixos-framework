# Pre-configured dnsmasq for local gateway / router.
#
# :::note
# This configuration reads the `network` conf in `config.yaml` file.
# :::

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
  wanInterface = network.gateway.wan.interface;
  lanInterface = "lan0"; # bridge for internal interfaces
  lanIpRange = gateway.lan.ip + "/" + toString gateway.lan.prefixLength;
in
{
  options = {
    darkone.service.dnsmasq.enable = lib.mkEnableOption "Enable local dnsmasq service";
  };

  # TODO: IPv6 (cf. arthur gw conf)
  config = lib.mkIf cfg.enable {

    networking = {

      # No IPv6 for the moment
      enableIPv6 = false;

      # Main configuration
      defaultGateway = {
        address = gateway.wan.gateway;
        interface = wanInterface;
      };
      nameservers = [
        gateway.wan.gateway
        "8.8.8.8"
        "8.8.4.4"
      ];

      # We need a bridge for dnsmasq settings
      bridges.${lanInterface}.interfaces = network.gateway.lan.interfaces;

      # Internet sharing / nat
      nat = {
        enable = true;
        externalInterface = gateway.wan.interface;
        internalIPs = [ lanIpRange ];
        internalInterfaces = [ lanInterface ];
      };

      # DHCP Clients
      useDHCP = false;
      interfaces = {
        ${wanInterface}.useDHCP = true;
        ${lanInterface} = {
          useDHCP = false;
          ipv4.addresses = [
            {
              address = gateway.lan.ip;
              inherit (gateway.lan) prefixLength;
            }
          ];
        };
      };

      # Firewall
      # 53 -> DNS
      # 67, 68 -> DHCP
      # 80 -> homepage / nginx
      firewall = {
        enable = true;
        allowPing = true;
        interfaces.${lanInterface} = {
          allowedTCPPorts = [
            22
            53
          ] ++ lib.optional config.services.nginx.enable 80;
          allowedUDPPorts = [
            53
            67
            68
          ];
        };
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
