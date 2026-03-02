# Coturn server (matrix).

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
      # Coturn Service
      #------------------------------------------------------------------------

      services.coturn = {
        enable = true;

        realm = turnDomain;

        listening-ips = [ host.ip ] ++ (lib.optional (host ? vpnIp) host.vpnIp);
        relay-ips = [ host.ip ];

        use-auth-secret = true;
        static-auth-secret-file = config.sops.secrets.turn-secret.path;

        # TODO: pas d'accès... utiliser security.acme à la place de caddy
        # cert = "/var/lib/caddy/storage/certificates/acme-v02.api.letsencrypt.org-directory/${turnDomain}/${turnDomain}.crt";
        # pkey = "/var/lib/caddy/storage/certificates/acme-v02.api.letsencrypt.org-directory/${turnDomain}/${turnDomain}.key";
        no-tls = true; # Desactivé pour le moment

        # Require authentication
        secure-stun = true;

        # https://github.com/coturn/coturn/blob/master/examples/etc/turnserver.conf
        # HCS host.ip is the external IP address (not the tailnet ip)
        extraConfig = ''
          #verbose
          log-file stdout
          no-multicast-peers
          total-quota=50
          external-ip=${host.ip}
        ''; # OR external-ip=${host.ip}/${host.vpnIp} ?
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = {
        allowedUDPPorts = [
          srv.listening-port # 3478
          srv.tls-listening-port # 5349
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
      };
    })
  ];
}
