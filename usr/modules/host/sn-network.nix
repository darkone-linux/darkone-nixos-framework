{ lib, config, ... }:
let
  cfg = config.darkone.host.sn-network;
  lanInterface = "enX0";
  gatewayAddress = "192.168.11.254";
in
{
  options = {
    darkone.host.sn-network.enable = lib.mkEnableOption "SN network gateway";
  };

  config = lib.mkIf cfg.enable {

    darkone = {
      host.vm.enableXen = true;
      theme.advanced.enable = true;
    };

    networking = {

      # Main configuration
      useDHCP = false;
      defaultGateway = {
        address = "${gatewayAddress}";
        interface = "${lanInterface}";
      };
      #defaultGateway6 = {
      #  address = "2001:XXXX:XXXX::1";
      #  interface = "${lanInterface}";
      #};
      nameservers = [
        "192.168.11.250"
        "192.168.11.150"
        "8.8.8.8"
        "8.8.4.4"
      ];

      # Firewall
      # 53 -> DNS
      # 67, 68 -> DHCP
      # 88 -> Kerberos
      # 135 -> RPC Active Directory
      firewall = {
        enable = true;
        allowPing = true;
        interfaces.${lanInterface} = {
          allowedTCPPorts = [
            22
            53
            135
          ];
          allowedUDPPorts = [
            53
            67
            68
          ];
        };
      };

      # IP Fixe pour l'interface de la VM
      interfaces.enX0 = {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = "192.168.11.250";
            prefixLength = 24;
          }
        ];
        #  ipv6.addresses = [
        #      { address = "FC00:XXXX:XXXX::7"; prefixLength = 64; }
        #  ];
      };

      # /etc/hosts
      hosts = {
        "192.168.11.1" = [
          "pc1"
          "lea"
        ];
        "192.168.11.2" = [
          "pc2"
          "max"
        ];
        "192.168.11.3" = [
          "pc3"
          "eli"
        ];
        "192.168.11.4" = [
          "pc4"
          "ben"
        ];
        "192.168.11.5" = [
          "pc5"
          "tom"
        ];
        "192.168.11.6" = [
          "pc6"
          "noe"
        ];
        "192.168.11.7" = [
          "pc7"
          "eve"
        ];
        "192.168.11.8" = [
          "pc8"
          "zoe"
        ];
        "192.168.11.10" = [
          "xoa"
          "xen-orchestra"
        ];
        "192.168.11.11" = [
          "homelab"
          "hl"
          "doc"
          "git"
        ];
        "192.168.11.135" = [ "switch-1" ];
        "192.168.11.137" = [ "switch-2" ];
        "192.168.11.150" = [
          "sn-zen"
          "snzen"
          "zen"
          "zential"
        ];
        "192.168.11.151" = [
          "sn-xen"
          "snxen"
          "xen"
          "dc1-samba.snzen"
        ];
        "192.168.11.250" = [ "sn-network" ];
        "192.168.11.254" = [
          "router"
          "routeur"
          "passerelle"
        ];
      };
    };

    services.dnsmasq = {
      enable = true;
      alwaysKeepRunning = true;

      settings = {
        domain = "sn-pm.lan";
        interface = "${lanInterface}";
        bind-interfaces = true;
        dhcp-authoritative = true;
        no-dhcp-interface = "lo";

        # Prends dans /etc/hosts les ips qui matchent le réseau en priorité
        localise-queries = true;
        expand-hosts = true;

        # Faster DHCP negotiation for IPv6
        #dhcp-rapid-commit = true;

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

        # Noms additionnels, cf. extraHosts
        #addn-hosts=/etc/nixos/dnsmasq-hosts.conf

        # Serveurs de nom
        server = config.networking.nameservers;

        # IP Fixes
        dhcp-host = [
          "A4:AE:12:2D:08:D8,192.168.11.1,SN-20-01,infinite"
          "A4:AE:12:2D:08:F2,192.168.11.2,SN-20-02,infinite"
          "A4:AE:12:2D:08:C0,192.168.11.3,SN-20-03,infinite"
          "A4:AE:12:2D:2A:D8,192.168.11.4,SN-20-04,infinite"
          "A4:AE:12:2D:08:C7,192.168.11.5,SN-20-05,infinite"
          "A4:AE:12:2D:2A:D4,192.168.11.6,SN-20-06,infinite"
          "A4:AE:12:2D:08:DB,192.168.11.7,SN-20-07,infinite"
          "A4:AE:12:2D:08:FA,192.168.11.8,SN-20-08,infinite"
          "4E:E5:5B:86:6D:46,192.168.11.10,XOA,infinite"
          "46:3c:74:69:7a:1f,192.168.11.11,HOMELAB,infinite"
          "69:D9:89:CB:07:EC,192.168.11.135,SW135,infinite"
          "CC:D5:39:51:94:54,192.168.11.137,SW137,infinite"
          "FA:7C:30:9D:52:92,192.168.11.150,SNZENTYAL,infinite"
          "6C:2B:59:89:C6:7F,192.168.11.151,XENSERVER,infinite"
          "EC:BD:1D:44:C9:8A,192.168.11.254,ROUTEUR-254,infinite"
        ];

        # Options DHCP : passerelle, serveur NTP, domaine
        dhcp-option = [
          "option:router,${config.networking.defaultGateway.address}"
          "option:dns-server,192.168.11.250"
          "option:ntp-server,193.55.120.12"
          "option:domain-name,sn-pm.lan"
        ];

        # Range DHCP pour les ordinateurs invités
        dhcp-range = [
          "192.168.11.200,192.168.11.230,24h"
          # Enable stateless IPv6 allocation
          #"::f,::ff,constructor:eth0,ra-stateless"
        ];

        # Forward des requêtes Active Directory
        # + ajouter 192.168.11.151 dc1-samba.snzen.sn-pm.lan dans /etc/hosts
        srv-host = [
          "_ldap._tcp.dc_msdcs.snzen.sn-pm.lan,192.168.11.151"
          "ldap._tcp.gc._msdcs.snzen.sn-pm.lan,192.168.11.151"
          "_kerberos._tcp.dc._msdcs.snzen.sn-pm.lan,192.168.11.151"
          "ldap._tcp.pdc._msdcs.snzen.sn-pm.lan,192.168.11.151"
        ];
      };
    };

    # TODO: to move
    system.stateVersion = "24.05";
  };
}
