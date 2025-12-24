# Tailscale client service for HCS.
#
# :::note
# A tailscale client to connect an external host to HCS.
# Do not use it to connect a gateway for a tailnet subnet.
# :::

{
  lib,
  pkgs,
  config,
  zone,
  network,
  ...
}:
let
  cfg = config.darkone.service.tailscale;
  coord = network.coordination;
  wanInterface = zone.gateway.wan.interface;
  hasHeadscale = coord.enable;
  isHcsSubnetGateway = hasHeadscale && cfg.isGateway;
  hcsFqdn = "${coord.domain}.${network.domain}";
  hcsInternalFqdn = network.zones.www.gateway.vpn.ipv4;
  caddyStorage = "/var/lib/caddy/storage"; # TODO: factorize with services.nix
  caddyStorTmp = "/tmp/caddy-storage-sync";
in
{
  options = {
    darkone.service.tailscale.enable = lib.mkEnableOption "Enable tailscale client to connect HCS";
    darkone.service.tailscale.isGateway = lib.mkEnableOption "This tailscale node is a subnet gateway";
    darkone.service.tailscale.isExitNode = lib.mkEnableOption "Configure this client as exit node";
  };

  config = lib.mkIf cfg.enable {

    #--------------------------------------------------------------------------
    # Security
    #--------------------------------------------------------------------------

    # Clé d'authentification hébergée par sops
    sops.secrets = lib.mkIf hasHeadscale {
      "tailscale/authKey" = {
        mode = "0400";
        owner = "root";
        group = "root";
      };
    };

    #--------------------------------------------------------------------------
    # Tailscale client service
    #--------------------------------------------------------------------------

    services.tailscale = lib.mkIf hasHeadscale {
      enable = true;

      # To use in conjonction with tailscale up --advertise-exit-node
      # https://search.nixos.org/options?channel=unstable&show=services.tailscale.useRoutingFeatures&query=services.tailscale
      # server -> enable IP forwarding.
      # client -> reverse path filtering will be set to loose instead of strict.
      # both -> client + server
      useRoutingFeatures = if (cfg.isExitNode || cfg.isGateway) then "both" else "client";

      # Clé du serveur préalablement enregistrée
      authKeyFile = config.sops.secrets."tailscale/authKey".path;

      # Enregistrement des adresses du réseau de zone et connexion au serveur
      # TODO: faire en sorte que ces paramètres soient fixés au démarrage de tailscaled,
      #       pour le moment il faut manuellement passer par "set" pour effectuer les réglages.
      extraUpFlags = [
        "--login-server"
        "https://${hcsFqdn}"
        (lib.mkIf cfg.isExitNode "--advertise-exit-node")
        "--accept-routes"
        "--accept-dns"

        # NOTE: pour le moment on peut laisser false mais on a plus MagicDNS, c'est
        # dnsmasq qui gère le DNS derrière AGH. Mais c'est compliqué et pas très propre.
        # Solution à étudier : tailscale gère le DNS avec AGH en intermédiaire.
        (lib.mkIf cfg.isGateway "false")
        "--ssh" # Usefull to sync TLS certificates with HCS caddy.
        "--reset" # Reload.
      ]
      ++ lib.optionals cfg.isGateway [
        "--advertise-routes"
        "${zone.networkIp}/${toString zone.prefixLength}"
        "--snat-subnet-routes" # source NAT traffic to local routes advertised with --advertise-routes
        "false"
      ];
    };

    #--------------------------------------------------------------------------
    # Networking
    #--------------------------------------------------------------------------

    # Autorisations réseau
    networking.firewall = lib.mkIf isHcsSubnetGateway {
      trustedInterfaces = [ "tailscale0" ];
      checkReversePath = "loose"; # subnet routing
      interfaces.${wanInterface}.allowedUDPPorts = [ config.services.tailscale.port ];
    };

    #--------------------------------------------------------------------------
    # Certificat sync
    #--------------------------------------------------------------------------
    # TODO: remontée d'info sur le bon fonctionnement de la synchro.

    # We need rsync
    environment.systemPackages = with pkgs; [
      rsync
      caddy
      openssl
    ];

    # Caddy storage directory creation if needed
    systemd.tmpfiles.rules = lib.mkIf isHcsSubnetGateway [ "d ${caddyStorage} 0750 caddy caddy -" ];

    # TLS certificates (caddy storage) sync service
    systemd.services.sync-caddy-certs = lib.mkIf isHcsSubnetGateway {
      description = "Sync Caddy certificates from VPS via Tailscale";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "nix";
        ExecStart = pkgs.writeShellScript "sync-hcs-caddy-certs" ''

          # Sync from HCS with nix user
          /run/current-system/sw/bin/mkdir -p ${caddyStorTmp}
          /run/wrappers/bin/sudo ${pkgs.coreutils}/bin/chown -R nix ${caddyStorTmp}

          # Certificates extraction
          ${pkgs.rsync}/bin/rsync \
            -avz \
            --delete \
            --timeout=30 \
            -e "${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new" \
            --rsync-path="sudo -u caddy rsync" \
            nix@${hcsInternalFqdn}:${caddyStorage}/ \
            ${caddyStorTmp}/

          # Sync to caddy data dir with caddy user
          /run/wrappers/bin/sudo ${pkgs.coreutils}/bin/chown -R caddy:caddy ${caddyStorTmp}
            
          # Sync with local tailscale
          /run/wrappers/bin/sudo ${pkgs.rsync}/bin/rsync \
            -av \
            --delete \
            ${caddyStorTmp}/ \
            ${caddyStorage}/
        '';
      };
    };

    # TLS certificates (caddy storage) sync timer
    systemd.timers.sync-caddy-certs = lib.mkIf isHcsSubnetGateway {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
        Persistent = true;
      };
    };
  };
}
