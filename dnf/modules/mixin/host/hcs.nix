# The main headscale coordination server. (wip)
#
# :::tip[A ready-to-use headscale server!]
# The network is configured in `usr/config.yaml` file.
# Additional enabled services (authentication, etc.)
# are automatically configured with consistent network plumbing on your
# global network.
#
# Zsh alias "h" for "headscale".
# :::

{
  lib,
  config,
  host,
  ...
}:
let
  cfg = config.darkone.host.hcs;
in
{
  options = {
    darkone.host.hcs.enable = lib.mkEnableOption "Enable headscale coordination server";
    darkone.host.hcs.enableFail2ban = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable fail2ban service";
    };
    darkone.host.hcs.enableClient = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable tailscale client on HCS node (recommande to host services)";
    };
    darkone.host.hcs.enableAuth = lib.mkOption {
      type = lib.types.bool;
      default = builtins.hasAttr "auth" host.services;
      description = "Enable authentication service (Authelia SSO)";
    };
    darkone.host.hcs.enableUsers = lib.mkOption {
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
      headscale.enable = true;
      tailscale = lib.mkIf cfg.enableClient {
        enable = true;
        isExitNode = true;
      };
      auth.enable = cfg.enableAuth;
      users.enable = cfg.enableUsers;
    };

    # Fail2ban
    services.fail2ban.enable = cfg.enableFail2ban;

    # Zsh aliases
    programs.zsh.shellAliases = {
      h = "sudo headscale";
    };
  };
}
