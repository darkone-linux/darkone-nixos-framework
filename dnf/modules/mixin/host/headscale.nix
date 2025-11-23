# The main headscale coordination server.
#
# :::tip[A ready-to-use headscale server!]
# The network is configured in `usr/config.yaml` file.
# Additional enabled services (authentication, etc.)
# are automatically configured with consistent network plumbing on your
# global network.
# :::

{
  lib,
  config,
  host,
  ...
}:
let
  cfg = config.darkone.host.headscale;
in
{
  options = {
    darkone.host.headscale.enable = lib.mkEnableOption "Enable headscale DNF server";
    darkone.host.headscale.enableFail2ban = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable fail2ban service";
    };
    darkone.host.headscale.enableAuth = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "auth" host.services;
      description = "Enable authentication service (Authelia SSO)";
    };
    darkone.host.headscale.enableUsers = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "users" host.services;
      description = "Enable user management with LLDAP for DNF SSO";
    };
  };

  config = lib.mkIf cfg.enable {

    # Is a server
    darkone.host.server.enable = true;

    # Enabled services
    darkone.service = {
      auth.enable = cfg.enableAuth;
      users.enable = cfg.enableUsers;
    };

    # Fail2ban
    services.fail2ban.enable = cfg.enableFail2ban;
  };
}
