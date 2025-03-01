# The gateway / NAS of local network.

{ lib, config, ... }:
let
  cfg = config.darkone.host.gateway;
in
{
  imports = [ ./minimal.nix ];

  options = {
    darkone.host.gateway.enable = lib.mkEnableOption "Enable gateway features for the current host (dhcp, dns, proxy, etc.).";
    darkone.host.gateway.enableNcps = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the proxy cache for packages";
    };
    darkone.host.gateway.enableForgejo = lib.mkEnableOption "Enable pre-configured forgejo git forge service.";
  };

  config = lib.mkIf cfg.enable {

    # Is a server
    darkone.host.server.enable = true;

    # Services
    darkone.service = {
      dnsmasq.enable = true;
      forgejo.enable = cfg.enableForgejo;
      ncps.enable = cfg.enableNcps;
    };
  };
}
