# A full-configured jellyfin server.

{
  lib,
  dnfLib,
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
  discoveryPorts = [
    1900
    7359
  ];
  musicDir = config.darkone.system.srv-dirs.music;
  videosDir = config.darkone.system.srv-dirs.videos;
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
          videosDir
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
        openFirewall = false;
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

      # Ouvre le port HTTP uniquement si on est pas sur le gateway (qui contient le reverse proxy)
      # et ouvre les ports de discovery sur l'interface interne uniquement.
      # https://github.com/NixOS/nixpkgs/blob/nixos-unstable/nixos/modules/services/misc/jellyfin.nix#L181
      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ httpPort ];
        allowedUDPPorts = discoveryPorts;
      };
    })
  ];
}
