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

  # TODO: IPv6 (cf. arthur gw conf)
  # TODO: headscale / tailscale integration
  config = lib.mkIf cfg.enable {

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

        # Domaine local ajouté aux noms DNS des machines assignées par le DHCP
        # -> Ne permet pas de gérer les machines des autres zones avec tailnet !
        domaine = lib.mkIf (!isTailscaleSubnet) zone.domain;

        interface = [
          lanInterface
          (lib.mkIf isTailscaleSubnet config.services.tailscale.interfaceName)
        ];

        # Contrairement à --bind-interfaces, se bind sur l'interface lan0 d'abord,
        # puis sur tailscale0 une fois que celle-ci est disponible.
        bind-dynamic = true; # Avoid conflicts with tailscale

        # https://man.archlinux.org/man/dnsmasq.8.fr#K,
        dhcp-authoritative = true;
        no-dhcp-interface = "lo";

        # Passer par le dns de headscale si on est un subnet tailnet (nul)
        #server = lib.optional isTailscaleSubnet "100.100.100.100";
        server = [
          "/${zone.domain}/#" # Do not forward my zone (-> loop: zone -> tailscale -> zone)
        ]

        # Other zones (not current, not www)
        ++ (lib.mapAttrsToList (_: z: "/${z.domain}/${z.gateway.vpn.ipv4}") (
          lib.filterAttrs (
            n: z: (n != "www" && n != zone.name && lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z)
          ) network.zones
        ))
        ++ [
          "94.140.14.14"
          "94.140.15.15"
          "1.1.1.1"
          "9.9.9.9"
        ];

        # Les requêtes pour ces domaines ne sont traitées qu'à partir de /etc/hosts ou de DHCP.
        # Elles ne sont pas transmises aux serveurs amont.
        local = "/${zone.domain}/";

        # Register the IP of gateway
        #address = [ "/${zone.gateway.hostname}.${zone.domain}/${zone.gateway.lan.ip}" ];

        # Utiliser un port DNS différent si adguardhome est activé.
        port = if hasAdguardHome then 5353 else 53;

        # Prends dans /etc/hosts les ips qui matchent le réseau en priorité.
        localise-queries = true;

        # local-name -> local-name.zone.domain.tld
        expand-hosts = true;

        # Accept DNS queries only from hosts whose address is on a local subnet.
        # Ne communiquer qu'avec les machines dans notre réseau.
        local-service = true;

        # Log results of all DNS queries
        log-queries = lib.mkDefault true;

        # Don't forward requests for the local address ranges (10.x.x.x) to upstream nameservers.
        # Fausse résolution inverse pour les réseaux privés. Toutes les requêtes DNS inverses pour des
        # adresses IP privées (ie 192.168.x.x, etc...) qui ne sont pas trouvées dans /etc/hosts ou dans
        # le fichier de baux DHCP se voient retournées une réponse "pas de tel domaine" ("no such domain")
        # au lieu d'être transmises aux serveurs de nom amont ("upstream server").
        bogus-priv = true;

        # Don't forward requests without dots or domain parts to upstream nameservers.
        # Indique à Dnsmasq de ne jamais transmettre en amont de requêtes A ou AAAA pour des noms simples,
        # c'est à dire ne comprenant ni points ni nom de domaine.
        # TODO: voir ce qu'on fait pour les noms simples des autres zones.
        domain-needed = true;

        # Main dhcp options + headscale return route
        # https://tailscale.com/kb/1019/subnets#disable-snat
        dhcp-option = [
          "option:netmask,255.255.0.0"
          "option:router,${zone.gateway.lan.ip}"
          "option:dns-server,${zone.gateway.lan.ip}"

          # Do not send a domaine name / search with tailnet!
          # -> Ne permet pas de gérer les machines des autres zones avec tailnet !
          (lib.mkIf (!isTailscaleSubnet) "option:domain-name,${zone.domain}")
          (lib.mkIf (!isTailscaleSubnet) "option:domain-search,${zone.domain}")

          # Pour le réseau 100.64.x.x, utilise le gateway local... (not working)
          #(lib.mkIf isTailscaleSubnet "121,100.64.0.0/10,${zone.gateway.lan.ip}")
        ];

        # Default: do not read /etc/resolv.conf, but headscale and adguardhome set it to false.
        # Ne pas lire le contenu du fichier /etc/resolv.conf. N'obtenir l'adresse des serveurs de nom
        # amont que depuis la ligne de commande ou le fichier de configuration de Dnsmasq.
        no-resolv = lib.mkDefault false;

        # Force dnsmasq à inclure l’IP réelle du client dans les requêtes DNS transmises en upstream.
        # Utile si adguardhome est derrière dnsmasq, ce qui n'est pas (plus) le cas ici.
        #edns-packet-max = 1232;
        #add-subnet = "32,128";
      }

      # Generated configuration in var/generated/network.nix
      # -> dhcp-host + dhcp-range + address
      // zone.extraDnsmasqSettings;
    };
  };
}
