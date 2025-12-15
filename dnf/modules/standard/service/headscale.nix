# A full-configured headscale service for HCS.

# TODO: ça marche mais on peut simplifier / optimiser.

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
  defaultParams = {
    inherit (network.coordination) domain;
    description = "Headscale DNF service";
    ip = srv.address;
    global = true;
    noRobots = false;
  };
  params = dnfLib.extractServiceParams host network "headscale" defaultParams;
in
{
  options = {
    darkone.service.headscale.enable = lib.mkEnableOption "Enable headscale DNF service";
    darkone.service.headscale.enableGRPC = lib.mkEnableOption "Open GRPC TCP port";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.headscale = {
        displayOnHomepage = false;
        inherit defaultParams;
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
            # -> Mettre un domaine interne ici pour éviter que les noms qui y sont attachés
            #    fuitent sur internet / les DNS externes. Mettre un nom du genre vpn.mondomaine.tld
            #    n'est pas une bonne idée !
            base_domain = "tailnet.internal";

            # Forcer l'utilisation de la conf DNS de headscale sur celle des noeuds
            override_local_dns = false;

            # ACLs (TODO)
            #acl_policy_path = "/var/lib/headscale/acls.json";

            # OIDC (pour intégration future avec Authelia)
            # https://github.com/juanfont/headscale/blob/9c4c017eac2e81908d2ae7d8d777e143a13a1772/config-example.yaml#L329
            # oidc = {
            #   issuer = "https://auth.mydomain.tld";
            #   client_id = "headscale";
            #   client_secret_path = "/var/lib/headscale/oidc_secret";
            # };

            # Serveurs DNS pour les clients
            # -> On ne résoud pas de NDD externes sur headscale pour le moment.
            nameservers = {
              global = [
                # "1.1.1.1"
                # "1.0.0.1"
                # "2606:4700:4700::1111"
                # "2606:4700:4700::1001"
              ];

              # A chaque suffixe de zone son IP tailnet
              # { "zone.domain.tld" = [ "100.64.x.x" ]; (...) };
              split = lib.concatMapAttrs (_: z: { "${z.domain}" = [ "${z.gateway.vpn.ipv4}" ]; }) (
                lib.filterAttrs (_: z: lib.hasAttrByPath [ "gateway" "vpn" "ipv4" ] z) network.zones
              );
            };

            # Domaines de recherche
            # -> Pas de recherche via headscale pour le moment.
            # zone1.domain.tld, zone2.domain.tld, etc.
            # With MagicDNS enabled, your tailnet base_domain is always the first search domain.
            # search_domains = [
            #   srv.settings.dns.base_domain
            # ]
            # ++ lib.attrsets.mapAttrsToList (_: z: z.domain) hcsClientZones;
            #search_domains = lib.attrsets.mapAttrsToList (_: z: z.domain) hcsClientZones;
            search_domains = [ "tailnet.internal" ];

            # Voir si on ne met pas ici les services globaux (MARCHE PAS - AUCUN EFFET)
            # A utiliser pour les global services ?
            # https://github.com/juanfont/headscale/blob/9c4c017eac2e81908d2ae7d8d777e143a13a1772/config-example.yaml#L312
            # extra_records = lib.attrsets.mapAttrsToList (_: z: {
            #   name = "${z.gateway.hostname}.${z.domain}";
            #   type = "A";
            #   value = "100.64.${z.ipPrefix}";
            # }) hcsClientZones;
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
