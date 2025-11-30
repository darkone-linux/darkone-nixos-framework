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
  hcsInternalFqdn = "${coord.hostname}.${coord.magicDnsSubDomain}.${network.domain}";
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
      extraUpFlags = [
        "--login-server"
        "https://${hcsFqdn}"
        (lib.mkIf cfg.isExitNode "--advertise-exit-node")
        "--accept-routes"
        "--accept-dns"
        (lib.mkIf cfg.isGateway "false")
        "--ssh" # Usefull to sync TLS certificates with HCS caddy.
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

    # We need rsync
    environment.systemPackages = with pkgs; [
      rsync
      caddy
      openssl
    ];

    # Caddy storage directory creation if needed
    systemd.tmpfiles.rules = lib.mkIf isHcsSubnetGateway [
      "d ${caddyStorTmp} 0700 nix users -"
      "d ${caddyStorage} 0750 caddy caddy -"
    ];

    # TLS certificates (caddy storage) sync service
    systemd.services.sync-caddy-certs = lib.mkIf isHcsSubnetGateway {
      description = "Sync Caddy certificates from VPS via Tailscale";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "nix";
        ExecStart = pkgs.writeShellScript "sync-hcs-caddy-certs" ''

          # Certificates extraction
          ${pkgs.rsync}/bin/rsync \
            -avz \
            --timeout=30 \
            -e "${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new" \
            --rsync-path="sudo -u caddy rsync" \
            nix@${hcsInternalFqdn}:${caddyStorage}/ \
            ${caddyStorTmp}/

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
