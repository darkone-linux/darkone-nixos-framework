# The main gateway / router of a local network zone.
#
# :::tip[A ready-to-use gateway!]
# The gateway is configured in `usr/config.yaml` file.
# Additional enabled services (homepage, adguardhome, forgejo, ncps...)
# are automatically configured with consistent network plumbing on the
# gateway and all machines on the local network.
# :::

{
  lib,
  config,
  network,
  zone,
  host,
  ...
}:
let
  cfg = config.darkone.host.gateway;
  wanInterface = zone.gateway.wan.interface;
  hasHeadscale = network.coordination.enable;
  hasAdguardHome = config.darkone.service.adguardhome.enable;
in
{
  options = {
    darkone.host.gateway.enable = lib.mkEnableOption "Enable gateway features for the current host (dhcp, dns, proxy, etc.)";
    darkone.host.gateway.enableFail2ban = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable fail2ban service";
    };
    darkone.host.gateway.enableAdguardhome = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "adguardhome" host.services;
      description = "Enable pre-configured Aguard Home service";
    };
    darkone.host.gateway.enableNcps = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "ncps" host.services;
      description = "Enable the proxy cache for packages";
    };
    darkone.host.gateway.enableAuth = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "auth" host.services;
      description = "Enable authentication service (Authelia SSO)";
    };
    darkone.host.gateway.enableUsers = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "users" host.services;
      description = "Enable user management with LLDAP for DNF SSO";
    };
  };

  config = lib.mkIf cfg.enable {

    # Is a server
    darkone.host.server.enable = true;

    #--------------------------------------------------------------------------
    # Gateway services
    #--------------------------------------------------------------------------

    # Enabled services
    darkone.service = {
      dnsmasq.enable = true;
      adguardhome.enable = cfg.enableAdguardhome;
      ncps.enable = cfg.enableNcps;
      auth.enable = cfg.enableAuth;
      users.enable = cfg.enableUsers;
    };

    # Fail2ban
    services.fail2ban.enable = cfg.enableFail2ban;

    #--------------------------------------------------------------------------
    # Tailscale
    #--------------------------------------------------------------------------

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

      # To use in conjonction with tailscale up --exit-node or --advertise-exit-node
      # https://search.nixos.org/options?channel=unstable&show=services.tailscale.useRoutingFeatures&query=services.tailscale
      # server -> enable IP forwarding.
      # client -> reverse path filtering will be set to loose instead of strict.
      # both -> client + server
      useRoutingFeatures = "both";

      # Clé du serveur préalablement enregistrée
      authKeyFile = config.sops.secrets."tailscale/authKey".path;

      # Enregistrement des adresses du réseau de zone et connexion au serveur
      extraUpFlags = [
        "--login-server"
        "https://${network.coordination.domainName}.${network.domain}"
        "--advertise-routes"
        "${zone.networkIp}/${toString zone.prefixLength}"
        "--snat-subnet-routes" # source NAT traffic to local routes advertised with --advertise-routes
        "false"
        "--accept-dns"
        "false"
        "--accept-routes"
        "--advertise-exit-node"
      ];
    };

    # Autorisations réseau
    networking.firewall = lib.mkIf hasHeadscale {
      trustedInterfaces = [ "tailscale0" ];
      checkReversePath = "loose"; # subnet routing
      interfaces.${wanInterface}.allowedUDPPorts = [ config.services.tailscale.port ];
    };

    #--------------------------------------------------------------------------
    # dnsmasq updates
    #--------------------------------------------------------------------------

    # If headscale is enabled but not adguardhome, we must have fallback DNS
    # servers to contact headscale coordination server.
    # no-resolv is false because tailscale client update resolv file.
    services.dnsmasq.settings = lib.mkIf (hasHeadscale && (!hasAdguardHome)) {
      no-resolv = false;
      server = config.services.headscale.settings.dns.nameservers.global;
    };
  };
}
