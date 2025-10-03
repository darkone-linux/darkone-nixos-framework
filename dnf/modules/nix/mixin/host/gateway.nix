# The main gateway / router of local network.
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
  host,
  ...
}:
let
  cfg = config.darkone.host.gateway;
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
    darkone.host.gateway.enableLldap = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "lldap" host.services;
      description = "Enable pre-configured lldap service (additional users & groups)";
    };
  };

  config = lib.mkIf cfg.enable {

    # Is a server
    darkone.host.server.enable = true;

    # Enabled services
    darkone.service = {
      dnsmasq.enable = true;
      adguardhome.enable = cfg.enableAdguardhome;
      ncps.enable = cfg.enableNcps;
      lldap.enable = cfg.enableLldap;
    };

    # Fail2ban
    services.fail2ban.enable = cfg.enableFail2ban;
  };
}
