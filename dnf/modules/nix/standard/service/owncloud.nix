# A full-configured owncloud.

{ lib, config, ... }:
let
  cfg = config.darkone.service.owncloud;
  ocCfg = config.services.ocis;
in
{
  options = {
    darkone.service.owncloud.enable = lib.mkEnableOption "Enable local owncloud (ocis) service";
    darkone.service.owncloud.domainName = lib.mkOption {
      type = lib.types.str;
      default = "owncloud";
      description = "Domain name for owncloud, nginx & hosts";
    };
  };

  config = lib.mkIf cfg.enable {

    # httpd + dnsmasq + homepage registration
    darkone.service.httpd = {
      enable = true;
      service.owncloud = {
        enable = true;
        inherit (cfg) domainName;
        displayName = "owncloud";
        description = "Cloud local";
        nginx.proxyPort = ocCfg.port;
      };
    };

    services.ocis = {
      enable = true;
    };
  };
}
