# Coturn server (matrix).
#
# Add DNS entries to optimize :
#
# ```
# Type,Name,Priority,Pds,Port,Target
# SRV,_stun._udp,0,0,3478,turn.mydomain.tld
# SRV,_stun._tcp,0,0,3478,turn.mydomain.tld
# SRV,_turn._udp,0,0,3478,turn.mydomain.tld
# SRV,_turn._tcp,0,0,3478,turn.mydomain.tld
# SRV,_turns._tcp,0,0,5349,turn.mydomain.tld
# ```

{
  lib,
  config,
  network,
  host,
  ...
}:
let
  cfg = config.darkone.service.turn;
  srv = config.services.coturn;
  turnDomain = "turn.${network.domain}";
in
{
  options = {
    darkone.service.turn.enable = lib.mkEnableOption "Enable local turn service (visio)";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.turn = {
        displayOnHomepage = false;
        proxy.enable = false;
      };
    }

    # TODO: Activer TLS, activer le service acme pour obtenir le certificat de turnDomain
    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.turn.enable = true;
      };

      #------------------------------------------------------------------------
      # Sops
      #------------------------------------------------------------------------

      sops.secrets.turn-secret = {
        mode = "0400";
        owner = "turnserver";
      };

      #------------------------------------------------------------------------
      # TLS (ACME DNS)
      #------------------------------------------------------------------------
      # TODO: service ACME indépendant

      # Dossier challenge caddy + acme
      systemd.tmpfiles.rules = [ "d /var/lib/acme/acme-challenge 0770 acme caddy -" ];

      security.acme = {
        acceptTerms = true;
        defaults.email = "admin+acme@${network.domain}";

        certs."${turnDomain}" = {

          # Groupe propriétaire du certificat
          # All certs are readable by the configured group.
          group = "caddy";

          # Si on utilise Caddy ou Nginx pour le port 80,
          # ACME peut utiliser un dossier partagé pour le challenge
          webroot = "/var/lib/acme/acme-challenge";

          # On demande à Coturn de recharger les certs quand ils sont renouvelés
          postRun = "systemctl restart coturn.service";
        };
      };

      # Caddy intercepte les requêtes de validation de Let's Encrypt pour notre domaine turn.
      services.caddy = {
        enable = true;
        virtualHosts."${turnDomain}" = {
          extraConfig = ''

            # Sert uniquement le challenge ACME
            handle_path /.well-known/acme-challenge/* {
              root * /var/lib/acme/acme-challenge/.well-known/acme-challenge
              file_server
            }

            # Reste des requêtes -> 200 OK
            handle {
              abort
            }
          '';
        };
      };

      # Accès au certificat par coturn
      users.users.turnserver.extraGroups = [
        "acme"
        "caddy"
      ];

      #------------------------------------------------------------------------
      # Coturn Service
      #------------------------------------------------------------------------

      services.coturn = {
        enable = true;
        realm = turnDomain;
        no-cli = true;
        no-tcp-relay = true;

        listening-ips = [ host.ip ] ++ (lib.optional (host ? vpnIp) host.vpnIp);
        relay-ips = [ host.ip ];

        use-auth-secret = true;
        static-auth-secret-file = config.sops.secrets.turn-secret.path;

        # TLS
        no-tls = false;
        cert = "/var/lib/acme/${turnDomain}/fullchain.pem";
        pkey = "/var/lib/acme/${turnDomain}/key.pem";

        # Require authentication
        secure-stun = true;

        # https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf
        # HCS host.ip is the external IP address (not the tailnet ip)
        extraConfig = ''
          #verbose
          log-file stdout
          no-multicast-peers

          total-quota=500
          user-quota=12 # max 12 allocations par utilisateur (suffisant pour 2-3 appels)
          max-allocate-timeout=3600

          external-ip=${host.ip}
          no-cli

          # on force l'usage de UDP quand possible (plus rapide...)
          no-tcp-relay

          # utile pour les clients mobiles qui changent de réseau (dégrade la connexion)
          mobility

          # recommandé pour WebRTC
          fingerprint

          # Blocage des réseaux privés non pertinents...
          denied-peer-ip=0.0.0.0-0.255.255.255
          denied-peer-ip=127.0.0.0-127.255.255.255
          denied-peer-ip=172.16.0.0-172.31.255.255
          denied-peer-ip=192.168.0.0-192.168.255.255

          # Autorisation de l'ip publique et des réseaux privés réels
          allowed-peer-ip=${host.ip}
          allowed-peer-ip=100.64.0.0-100.127.255.255
          allowed-peer-ip=10.0.0.0-10.255.255.255

          # On force des ciphers modernes (TLS)
          #cipher-list="ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
        ''; # OR external-ip=${host.ip}/${host.vpnIp} -> NOT WORKING
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = {
        allowedUDPPorts = [
          srv.listening-port # 3478
          # srv.tls-listening-port # 5349
        ];
        allowedTCPPorts = [
          srv.listening-port # 3478
          srv.tls-listening-port # 5349
        ];
        allowedUDPPortRanges = [
          {
            from = srv.min-port; # 49152
            to = srv.max-port; # 65535
          }
        ];
        allowedTCPPortRanges = [
          {
            from = srv.min-port; # 49152
            to = srv.max-port; # 65535
          }
        ];
      };
    })
  ];
}
