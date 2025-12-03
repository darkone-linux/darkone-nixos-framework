# Netdata supervision module.
#
# :::caution
# The interface of this application contains too much encouragement
# to use the “pro” version, so it is better to use the “monitoring” module.
# :::

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.netdata;
in
{
  options = {
    darkone.service.netdata.enable = lib.mkEnableOption "Enable netdata application";
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.netdata = {
        persist.dirs = [ "/var/lib/netdata" ];
        proxy.servicePort = 19999;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.netdata.enable = true;
      };

      #networking.firewall.allowedTCPPorts = [ 19999 ];
      services.netdata = {
        enable = true;
        config = {
          global = {
            "memory mode" = "ram";
            "debug log" = "none";
            "access log" = "none";
            "error log" = "syslog";
          };
        };
      };

      nixpkgs.config.allowUnfree = true;
      services.netdata.package = pkgs.netdata.override { withCloudUi = true; };
    })
  ];
}
