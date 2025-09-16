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
      useNetworkd = true;
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
      # 8501 -> packages proxy (ncps)
      firewall = {
        enable = true;
        allowPing = true;
        interfaces.${lanInterface} = {
          allowedTCPPorts = [
            22
            53
            5353
          ]
          ++ lib.optional config.services.nginx.enable 80
          ++ lib.optional config.darkone.service.ncps.enable 8501;
          allowedUDPPorts = [
            53
            5353
            67
            68
          ];
        };
      };

      # /etc/hosts + avoid additional loopback entries in 127.0.0.2
      hosts = (extraNetworking.hosts or { }) // {
        "127.0.0.2" = lib.mkForce [ ];
      };
    };

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

    services.dnsmasq = {
      enable = true;
      alwaysKeepRunning = true;

      settings = {
        inherit domain;
        interface = lanInterface;
        bind-interfaces = true;
        dhcp-authoritative = true;
        no-dhcp-interface = "lo";

        # Utiliser un port DNS différent si adguardhome est activé
        port = if config.darkone.service.adguardhome.enable then 5353 else 53;

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
        server =
          if config.darkone.service.adguardhome.enable then
            [ "127.0.0.1#5353" ]
          else
            config.networking.nameservers;
      }
      // extraDnsmasqSettings;
    };
  };
}
