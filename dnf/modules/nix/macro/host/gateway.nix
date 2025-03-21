# The gateway / NAS of local network.
#
# :::tip[A ready-to-use gateway]
# The gateway is configured in `config.yaml` file.
# Services for hosts (homepage, forgejo, nix package cache...)
# are automatically configured on each machine.
# :::

{
  lib,
  config,
  network,
  ...
}:
let
  cfg = config.darkone.host.gateway;
  inherit (network) gateway;
in
{
  imports = [ ./minimal.nix ];

  options = {
    darkone.host.gateway.enable = lib.mkEnableOption "Enable gateway features for the current host (dhcp, dns, proxy, etc.).";
    darkone.host.gateway.enableNcps = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem "ncps" gateway.services;
      description = "Enable the proxy cache for packages";
    };
    darkone.host.gateway.enableHomepage = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem "homepage" gateway.services;
      description = "Enable the auto-configured homepage service";
    };
    darkone.host.gateway.enableForgejo = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem "forgejo" gateway.services;
      description = "Enable pre-configured forgejo git forge service";
    };
    darkone.host.gateway.enableLldap = lib.mkOption {
      type = lib.types.bool;
      default = builtins.elem "lldap" gateway.services;
      description = "Enable pre-configured lldap service (additional users & groups)";
    };
  };

  config = lib.mkIf cfg.enable {

    # Is a server
    darkone.host.server.enable = true;

    # Services
    darkone.service = {
      dnsmasq.enable = true;
      ncps.enable = cfg.enableNcps;
      forgejo.enable = cfg.enableForgejo;
      homepage.enable = cfg.enableHomepage;
      lldap.enable = cfg.enableLldap;
    };
  };
}
