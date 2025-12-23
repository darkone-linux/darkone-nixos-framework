# A full-configured jellyfin server.

{
  lib,
  config,
  host,
  zone,
  pkgs,
  ...
}:
let
  cfg = config.darkone.service.jellyfin;
  srv = config.services.jellyfin;
  httpPort = 8096;
  isGateway =
    lib.attrsets.hasAttrByPath [ "gateway" "hostname" ] zone && host.hostname == zone.gateway.hostname;
  musicDir = config.darkone.system.srv-dirs.music;
  videoDir = config.darkone.system.srv-dirs.video;
in
{
  options = {
    darkone.service.jellyfin.enable = lib.mkEnableOption "Enable jellyfin service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.jellyfin = {
        persist.dirs = [ srv.dataDir ];
        persist.varDirs = [ srv.cacheDir ];
        persist.mediaDirs = [
          musicDir
          videoDir
        ];
        proxy.servicePort = httpPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.jellyfin.enable = true;
      };

      #------------------------------------------------------------------------
      # jellyfin Service
      #------------------------------------------------------------------------

      services.jellyfin = {
        enable = true;
        openFirewall = !isGateway;
        group = "common-files";
      };

      #------------------------------------------------------------------------
      # Dependencies
      #------------------------------------------------------------------------

      # Music directory
      darkone.system.srv-dirs.enableMedias = true;
      systemd.services.jellyfin.serviceConfig.UMask = lib.mkForce "0006";
      users.users.jellyfin.extraGroups = [ "common-files" ];

      # jellyfin
      # jellyfin-web
      environment.systemPackages = with pkgs; [ jellyfin-ffmpeg ];

      # https://jellyfin.org/docs/general/networking/index.html
      networking.firewall.interfaces.lan0 = lib.mkIf isGateway {
        allowedTCPPorts = [ httpPort ];
        allowedUDPPorts = [ 7359 ]; # Service discovery
      };
    })
  ];
}
