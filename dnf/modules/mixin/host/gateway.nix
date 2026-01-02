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
  host,
  ...
}:
let
  cfg = config.darkone.host.gateway;
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
    darkone.host.gateway.enableIdm = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "idm" host.services;
      description = "Enable identity manager (kanidm)";
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
      #auth.enable = cfg.enableAuth;
      #users.enable = cfg.enableUsers;
      dnsmasq.enable = true;
      adguardhome.enable = cfg.enableAdguardhome;
      idm.enable = cfg.enableIdm;
      tailscale = lib.mkIf hasHeadscale {
        enable = true;
        isGateway = true;
        isExitNode = true;
      };
      fail2ban.enable = cfg.enableFail2ban;
    };

    #--------------------------------------------------------------------------
    # dnsmasq updates
    #--------------------------------------------------------------------------

    # If headscale is enabled but not adguardhome, we must have fallback DNS
    # servers to contact headscale coordination server. (wip)
    services.dnsmasq.settings = lib.mkIf (hasHeadscale && (!hasAdguardHome)) {

      # no-resolv is false because tailscale client update the resolv file.
      no-resolv = false;

      # DNS upstreams are headscale DNS upstreams.
      server = config.services.headscale.settings.dns.nameservers.global;
    };
  };
}
