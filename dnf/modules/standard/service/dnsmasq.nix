# Pre-configured dnsmasq for local gateway / router.
#
# :::note
# This configuration reads the `network` conf in `config.yaml` file.
# It is the essential functionality of the local gateway.
# :::

{
  lib,
  config,
  zone,
  ...
}:
let
  cfg = config.darkone.service.dnsmasq;
  inherit (zone) domain;
  inherit (zone) extraDnsmasqSettings;
  inherit (zone) gateway;
  wanInterface = gateway.wan.interface;
  lanInterface = "lan0"; # bridge for internal interfaces
  lanIpRange = zone.networkIp + "/" + toString zone.prefixLength;
in
{
  options = {
    darkone.service.dnsmasq.enable = lib.mkEnableOption "Enable local dnsmasq service";
  };

  # TODO: IPv6 (cf. arthur gw conf)
  # TODO: headscale / tailscale integration
  config = lib.mkIf cfg.enable {

    networking = {

      # No IPv6 for the moment
      enableIPv6 = false;

      # Local domain
      inherit (zone) domain;

      # Probably useless with headscale magicdns?
      search = [ zone.domain ];

      # We need a bridge for dnsmasq settings
      bridges.${lanInterface}.interfaces = gateway.lan.interfaces;

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
          allowedTCPPorts =
            [
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

      settings =
        {
          inherit domain;

          interface = [ lanInterface ];
          bind-interfaces = true;
          dhcp-authoritative = true;
          no-dhcp-interface = "lo";

          # Les requêtes pour ces domaines ne sont traitées qu'à partir de /etc/hosts ou de DHCP.
          # Elles ne sont pas transmises aux serveurs amont.
          local = "/${domain}/";

          # Register the IP of gateway
          #address = [ "/${gateway.hostname}.${domain}/${gateway.lan.ip}" ];

          # Utiliser un port DNS différent si adguardhome est activé.
          port = if config.darkone.service.adguardhome.enable then 5353 else 53;

          # Filtrer les requêtes DNS inutiles provenant de Windows qui peuvent être déclenchées.
          filterwin2k = true;

          # Prends dans /etc/hosts les ips qui matchent le réseau en priorité.
          localise-queries = true;

          # local-name = local-name.domain
          expand-hosts = true;

          # Accept DNS queries only from hosts whose address is on a local subnet
          local-service = true;

          # Log results of all DNS queries
          log-queries = true;

          # Don't forward requests for the local address ranges (10.x.x.x)
          # to upstream nameservers
          bogus-priv = true;

          # Don't forward requests without dots or domain parts to upstream nameservers
          domain-needed = false;

          # Dnsmasq récupère ses serveurs DNS amont à partir des fichiers "server"
          # au lieu de /etc/resolv.conf ou tout autre fichier.
          no-resolv = config.darkone.service.adguardhome.enable;
          #server =
          #  if config.darkone.service.adguardhome.enable then
          #    [ ("127.0.0.1#" + (toString config.services.adguardhome.settings.dns.port)) ]
          #  else
          #    config.networking.nameservers;

          # Force dnsmasq à inclure l’IP réelle du client dans les requêtes DNS transmises en upstream.
          # Utile si adguardhome est derrière dnsmasq, ce qui n'est pas (plus) le cas ici.
          #edns-packet-max = 1232;
          #add-subnet = "32,128";
        }

        # Generated configuration in var/generated/network.nix
        // extraDnsmasqSettings;
    };
  };
}
