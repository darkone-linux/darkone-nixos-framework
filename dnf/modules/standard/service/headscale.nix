# A full-configured headscale service for HCS.

{
  lib,
  dnfLib,
  config,
  network,
  host,
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
  params = dnfLib.extractServiceParams host network "headscale" {
    inherit (network.coordination) domain;
    description = "Headscale DNF service";
    global = true;
  };
in
{
  options = {
    darkone.service.headscale.enable = lib.mkEnableOption "Enable headscale DNF service";
    darkone.service.headscale.enableGRPC = lib.mkEnableOption "Open GRPC TCP port";
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.headscale = {
        inherit params;
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

      # TODO: Derp relay, ACLs, OIDC
      services.headscale = {
        enable = true;
        settings = {

          # URL publique du serveur Headscale
          server_url = "https://${params.fqdn}:443";

          # Configuration DNS
          dns = {

            # MagicDNS activé (default)
            magic_dns = true;

            # Domaine de base pour MagicDNS
            base_domain = "${network.coordination.magicDnsSubDomain}.${network.domain}";

            # Forcer l'utilisation de la conf DNS de headscale sur celle des noeuds
            #override_local_dns = true;

            # ACLs
            #acl_policy_path = "/var/lib/headscale/acls.json";

            # # OIDC (pour intégration future avec Authelia)
            # https://github.com/juanfont/headscale/blob/9c4c017eac2e81908d2ae7d8d777e143a13a1772/config-example.yaml#L329
            # oidc = {
            #   issuer = "https://auth.mydomain.tld";
            #   client_id = "headscale";
            #   client_secret_path = "/var/lib/headscale/oidc_secret";
            # };

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
            search_domains = [ srv.settings.dns.base_domain ];
            #++ lib.attrsets.mapAttrsToList (_: z: z.domain) hcsClientZones;

            # Voir si on ne met pas ici les services globaux (MARCHE PAS)
            # A utiliser pour les global services ?
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

      # TODO: to activate or abandon
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
