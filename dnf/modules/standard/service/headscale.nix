# A full-configured headscale service for HCS.

{
  lib,
  config,
  network,
  ...
}:
let
  cfg = config.darkone.service.headscale;
  srv = config.services.headscale;
  hcsClientZones =
    if network.coordination.enable then
      lib.filterAttrs (_: z: z.domain != network.domain) network.zones
    else
      { };
in
{
  options = {
    darkone.service.headscale.enable = lib.mkEnableOption "Enable headscale DNF service";
    darkone.service.headscale.enableGRPC = lib.mkEnableOption "Open GRPC TCP port";
    darkone.service.headscale.appName = lib.mkOption {
      type = lib.types.str;
      default = "Headscale DNF Service";
      description = "Title of the headscale service";
    };
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.headscale = {
        inherit (network.coordination) domainName;
        displayOnHomepage = false;
        displayName = "Headscale";
        description = "Headscale DNF service";
        persist.dirs = [ "/var/lib/headscale" ];
        proxy.servicePort = srv.port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.headscale.enable = true;
      };

      #------------------------------------------------------------------------
      # Headscale main configuration
      #------------------------------------------------------------------------

      services.headscale = {
        enable = true;
        settings = {

          # URL publique du serveur Headscale
          server_url = "https://${network.coordination.domainName}.${network.domain}:443";

          # Configuration DNS
          dns = {

            # MagicDNS activé (default)
            magic_dns = true;

            # Domaine de base pour MagicDNS
            base_domain = "${network.coordination.magicDnsSubDomain}.${network.domain}";
            #base_domain = "${network.domain}";

            # Forcer l'utilisation de la conf DNS de headscale sur celle des noeuds
            #override_local_dns = true;

            # Serveurs DNS pour les clients
            nameservers = {
              global = [
                "1.1.1.1"
                "1.0.0.1"
                "2606:4700:4700::1111"
                "2606:4700:4700::1001"
              ];

              # { "zone.domain.tld" = [ "100.64.x.x" ]; (...) };
              split = lib.concatMapAttrs (_: z: { "${z.domain}" = [ "${z.gateway.vpn.ipv4}" ]; }) (
                lib.filterAttrs (_: z: lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z) network.zones
              );
            };

            # Domaines de recherche
            # zone1.domain.tld, zone2.domain.tld, etc.
            # With MagicDNS enabled, your tailnet base_domain is always the first search domain.
            search_domains = [
              srv.settings.dns.base_domain
            ]
            ++ lib.attrsets.mapAttrsToList (_: z: z.domain) hcsClientZones;

            # Voir si on ne met pas ici les services globaux (MARCHE PAS)
            # https://github.com/juanfont/headscale/blob/9c4c017eac2e81908d2ae7d8d777e143a13a1772/config-example.yaml#L312
            extra_records = lib.attrsets.mapAttrsToList (_: z: {
              name = "${z.gateway.hostname}.${z.domain}";
              type = "A";
              value = "100.64.${z.ipPrefix}";
            }) hcsClientZones;
          };
        };
      };

      #------------------------------------------------------------------------
      # TLS certificates sync
      #------------------------------------------------------------------------

      # TODO: to activate
      services.rsyncd = lib.mkIf false {
        enable = true;
        settings = {
          globalSection = {
            address = "0.0.0.0";
            uid = "nobody";
            gid = "nobody";
            "max connections" = 2;
            "use chroot" = true;
          };
          sections = {
            caddy-certs = {
              "auth users" = [ "nix" ];
              "read only" = "yes";
              comment = "Certificats publics Let’s Encrypt";
              path = "/var/lib/caddy-export";
            };
          };
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

# headscale.settings:

# Adresse d'écoute pour les métriques (optionnel)
#metrics_listen_addr = "127.0.0.1:9090";

# Préfixe IP pour le réseau VPN (default)
#prefixes = {
#  v4 = "100.64.0.0/10";  # Plage Tailscale standard
#};

# Configuration de la base de données (default)
# SQLite par défaut, mais PostgreSQL recommandé en production
# database = {
#   type = "sqlite3";
#   sqlite = {
#     path = "/var/lib/headscale/db.sqlite";
#   };
# };

# Configuration DERP (relais pour NAT traversal)
# derp = {
#   server = {
#     enabled = true;
#     region_id = 999;
#     region_code = "custom";
#     region_name = "Custom DERP";
#     stun_listen_addr = "0.0.0.0:3478";
#   };

#   # URLs des serveurs DERP (default)
#   # urls = [
#   #   "https://controlplane.tailscale.com/derpmap/default"
#   # ];

#   # Auto-update de la DERP map
#   # auto_update_enabled = true; # default
#   # update_frequency = "24h"; # default
# };

# Désactiver les mises à jour automatiques (géré par NixOS) (n'existe pas)
# disable_check_updates = true;

# Durée de vie des éphemeral nodes (default)
# ephemeral_node_inactivity_timeout = "30m";

# ACLs - Configuration basique, à affiner
# acl_policy_path = "/var/lib/headscale/acls.json";

# # OIDC (pour intégration future avec Authelia)
# https://github.com/juanfont/headscale/blob/9c4c017eac2e81908d2ae7d8d777e143a13a1772/config-example.yaml#L329
# oidc = {
#   # issuer = "https://auth.mydomain.tld";
#   # client_id = "headscale";
#   # client_secret_path = "/var/lib/headscale/oidc_secret";
# };

# Configuration des logs (default)
# log = {
#   level = "info";
#   format = "text";
# };

# Unix socket used for the CLI to connect without authentication (déjà une valeur)
#unix_socket = "/var/run/headscale/headscale.sock";
#unix_socket_permission = "0770";
