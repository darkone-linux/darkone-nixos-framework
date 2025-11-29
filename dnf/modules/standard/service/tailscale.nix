# Tailscale client service for HCS.
#
# :::note
# A tailscale client to connect an external host to HCS.
# Do not use it to connect a gateway for a tailnet subnet.
# :::

{
  lib,
  config,
  network,
  ...
}:
let
  cfg = config.darkone.service.tailscale;
  hasHeadscale = network.coordination.enable;
in
{
  options = {
    darkone.service.tailscale.enable = lib.mkEnableOption "Enable tailscale client to connect HCS";
    darkone.service.tailscale.isExitNode = lib.mkEnableOption "Configure this client as exit node";
  };

  config = lib.mkIf cfg.enable {

    # Clé d'authentification hébergée par sops
    sops.secrets = lib.mkIf hasHeadscale {
      "tailscale/authKey" = {
        mode = "0400";
        group = "root";
      };
    };

    # Client tailscale
    services.tailscale = lib.mkIf hasHeadscale {
      enable = true;

      # To use in conjonction with tailscale up --advertise-exit-node
      # https://search.nixos.org/options?channel=unstable&show=services.tailscale.useRoutingFeatures&query=services.tailscale
      # server -> enable IP forwarding.
      # client -> reverse path filtering will be set to loose instead of strict.
      # both -> client + server
      useRoutingFeatures = if cfg.isExitNode then "both" else "client";

      # Clé du serveur préalablement enregistrée
      authKeyFile = config.sops.secrets."tailscale/authKey".path;

      # Enregistrement des adresses du réseau de zone et connexion au serveur
      extraUpFlags = [
        "--login-server"
        "https://${network.coordination.domain}.${network.domain}"
        (lib.mkIf cfg.isExitNode "--advertise-exit-node")
        "--accept-routes"
        "--accept-dns"
      ];
    };
  };
}
