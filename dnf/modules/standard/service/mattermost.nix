# A mattermost server. (WIP)
#
# :::caution
# This module works with Mattermost Team Edition but I do not plan
# to maintain it because of the removal of the SSO functionality
# from the open-source version.
# :::

{
  lib,
  pkgs,
  config,
  host,
  ...
}:
let
  cfg = config.darkone.service.mattermost;
  srv = config.services.mattermost;
in
{
  options = {
    darkone.service.mattermost.enable = lib.mkEnableOption "Enable mattermost service";
    darkone.service.mattermost.domainName = lib.mkOption {
      type = lib.types.str;
      default = "mattermost";
      description = "Domain name for mattermost, registered in network configuration";
    };
    darkone.service.mattermost.appName = lib.mkOption {
      type = lib.types.str;
      default = "Mattermost";
      description = "Default title for mattermost service";
    };
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.mattermost = {
        inherit (cfg) domainName;
        displayName = "Mattermost";
        description = "Communication solution";
        persist.dirs = [ srv.dataDir ];
        proxy.servicePort = srv.port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.mattermost.enable = true;
      };

      # Tools
      environment.systemPackages = with pkgs; [ mmctl ];

      # Mattermost server
      services.mattermost = {
        enable = true;
        siteUrl = "https://${cfg.domainName}.${host.networkDomain}";
      };
    })
  ];
}
