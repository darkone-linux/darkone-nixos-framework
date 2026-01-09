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
        # listening-port = 3478;
        # tls-listening-port = 5349;

        listening-ips = [ host.ip ] ++ (lib.optional (host ? vpnIp) host.vpnIp);
        relay-ips = [ host.ip ];

        # min-port = 49152;
        # max-port = 65535;

        use-auth-secret = true;
        static-auth-secret-file = config.sops.secrets.turn-secret.path;

        # TODO: pas d'accès... utiliser security.acme à la place de caddy
        # cert = "/var/lib/caddy/storage/certificates/acme-v02.api.letsencrypt.org-directory/${turnDomain}/${turnDomain}.crt";
        # pkey = "/var/lib/caddy/storage/certificates/acme-v02.api.letsencrypt.org-directory/${turnDomain}/${turnDomain}.key";

        #no-tcp = true;
        secure-stun = false;

        extraConfig = ''
          verbose
          log-file stdout
          no-multicast-peers
          total-quota=50
        '';
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = {
        allowedUDPPorts = [
          srv.listening-port
          #srv.tls-listening-port
        ];
        allowedTCPPorts = [
          srv.listening-port
          #srv.tls-listening-port
        ];
        allowedUDPPortRanges = [
          {
            from = srv.min-port;
            to = srv.max-port;
          }
        ];
      };
    })
  ];
}
