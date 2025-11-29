# A mattermost server. (WIP)
#
# :::caution
# This module works with Mattermost Team Edition but I do not plan
# to maintain it because of the removal of the SSO functionality
# from the open-source version.
# :::

{
  lib,
  dnfLib,
  pkgs,
  config,
  host,
  ...
}:
let
  cfg = config.darkone.service.mattermost;
  srv = config.services.mattermost;
  params = dnfLib.extractServiceParams host "mattermost" { };
in
{
  options = {
    darkone.service.mattermost.enable = lib.mkEnableOption "Enable mattermost service";
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.mattermost = {
        inherit params;
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
        siteUrl = params.href;
      };
    })
  ];
}
