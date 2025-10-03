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
    darkone.service.netdata.domainName = lib.mkOption {
      type = lib.types.str;
      default = "netdata";
      description = "Domain name for netdata, registered in nginx & hosts";
    };
  };

  config = lib.mkIf cfg.enable {

    # httpd + dnsmasq + homepage registration
    darkone.service.httpd = {
      enable = true;
      service.netdata = {
        enable = true;
        inherit (cfg) domainName;
        displayName = "Netdata";
        description = "Outil de supervision";
        nginx.proxyPort = 19999;
      };
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
  };
}
