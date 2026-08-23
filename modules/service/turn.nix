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
  dnfLib,
  dnfConfig,
  config,
  network,
  host,
  ...
}:
let
  cfg = config.darkone.service.turn;
  srv = config.services.coturn;
  turnDomain = "turn.${network.domain}";

  # UDP media relay range, in the registry so no neighbouring service can be
  # given a port coturn hands out (cf. config/network.nix). Shaped for
  # `allowedUDPPortRanges`, which the firewall below reuses as-is.
  relayRange = {
    from = dnfConfig.network.ports.turnRelayStart;
    to = dnfConfig.network.ports.turnRelayEnd;
  };
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
      darkone.system.services = dnfLib.enableBlock "turn";

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
      # TODO: standalone ACME service

      # Dossier challenge caddy + acme
      systemd.tmpfiles.rules = [ "d /var/lib/acme/acme-challenge 0770 acme caddy -" ];

      security.acme = {
        acceptTerms = true;
        defaults.email = "admin+acme@${network.domain}";

        certs."${turnDomain}" = {

          # Certificate owner group
          # All certs are readable by the configured group.
          group = "caddy";

          # Si on utilise Caddy ou Nginx pour le port 80,
          # ACME can use a shared folder for the challenge
          webroot = "/var/lib/acme/acme-challenge";

          # Ask Coturn to reload certs when renewed
          postRun = "systemctl restart coturn.service";
        };
      };

      # Caddy intercepts Let's Encrypt validation requests for our turn domain.
      services.caddy = {
        enable = true;
        virtualHosts."${turnDomain}" = {
          extraConfig = ''

            # Sert uniquement le challenge ACME
            handle_path /.well-known/acme-challenge/* {
              root * /var/lib/acme/acme-challenge/.well-known/acme-challenge
              file_server
            }

            # Remaining requests -> 200 OK
            handle {
              abort
            }
          '';
        };
      };

      # Certificate access for coturn
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

        # Media relays stay UDP-only (clients may still reach coturn over TCP).
        no-tcp-relay = true;

        listening-ips = [ host.ip ] ++ (lib.optional (host ? vpnIp) host.vpnIp);
        relay-ips = [ host.ip ];

        # Relay range: both bounds come from the registry, `max-port` included,
        # so the range the firewall opens is exactly the one coturn allocates.
        min-port = relayRange.from;
        max-port = relayRange.to;

        use-auth-secret = true;
        static-auth-secret-file = config.sops.secrets.turn-secret.path;

        # TLS
        no-tls = false;
        cert = "/var/lib/acme/${turnDomain}/fullchain.pem";
        pkey = "/var/lib/acme/${turnDomain}/key.pem";

        # Anonymous STUN Binding must stay allowed (coturn default, restated
        # here because the opposite looks safer than it is): libwebrtc never
        # authenticates a Binding request, so rejecting it costs every client
        # its server-reflexive candidate. Only host and relay candidates then
        # remain, no direct path is ever tried and every call is relayed.
        # Allocations stay authenticated by `use-auth-secret`.
        secure-stun = false;

        # https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf
        # HCS host.ip is the external IP address (not the tailnet ip)
        extraConfig = ''
          #verbose
          log-file stdout
          no-multicast-peers

          # One allocation per (announced turn uri x interface x address
          # family), not one per call: a phone on wifi + cellular already
          # spends 6, and Element reuses the same coturn username for the
          # whole `turn_user_lifetime`, so consecutive calls stack up until
          # the allocations expire: 12 could be reached on a redial.
          total-quota=500
          user-quota=50

          external-ip=${host.ip}

          # useful for mobile clients switching networks (degrades connection)
          mobility

          # recommended for WebRTC
          fingerprint

          # Block irrelevant private networks...
          denied-peer-ip=0.0.0.0-0.255.255.255
          denied-peer-ip=127.0.0.0-127.255.255.255
          denied-peer-ip=172.16.0.0-172.31.255.255
          denied-peer-ip=192.168.0.0-192.168.255.255
          denied-peer-ip=100.64.0.0-100.127.255.255
          denied-peer-ip=10.0.0.0-10.255.255.255

          # Authorize public IP and actual private networks
          allowed-peer-ip=${host.ip}
          #allowed-peer-ip=100.64.0.0-100.127.255.255
          #allowed-peer-ip=10.0.0.0-10.255.255.255

          # Force modern ciphers (TLS)
          cipher-list="ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
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

        # Media relay is UDP-only (no-tcp-relay): no TCP relay range needed.
        allowedUDPPortRanges = [ relayRange ];
      };
    })
  ];
}
