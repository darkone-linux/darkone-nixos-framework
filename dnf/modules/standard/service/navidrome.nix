# A full-configured navidrome service.

{
  lib,
  dnfLib,
  config,
  network,
  zone,
  host,
  ...
}:
let
  cfg = config.darkone.service.navidrome;
  srv = config.services.navidrome.settings;
  defaultParams = {
    description = "Music browser & player";
  };
  params = dnfLib.extractServiceParams host network "navidrome" defaultParams;
  musicDir = config.darkone.system.dirs.music;
in
{
  options = {
    darkone.service.navidrome.enable = lib.mkEnableOption "Enable navidrome service";
    # darkone.service.navidrome.enableNfsShare = lib.mkOption {
    #   type = lib.types.bool;
    #   default = true;
    #   description = "Enable music directory NFS share";
    # };
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.navidrome = {
        inherit defaultParams;
        persist = {
          mediaDirs = [ srv.MusicFolder ];
          varDirs = lib.mkIf (lib.hasAttr "CacheFolder" srv) [ srv.CacheFolder ];
          dirs = lib.mkIf (lib.hasAttr "DataFolder" srv) [ srv.DataFolder ];
        };
        proxy.servicePort = srv.Port;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.navidrome.enable = true;
      };

      #------------------------------------------------------------------------
      # Naviderome dependencies
      #------------------------------------------------------------------------

      # Create common-files account
      darkone.service.beets.enable = true;
      #darkone.service.beets.enableService = true;

      # Music directory
      systemd.tmpfiles.rules = [ "d ${musicDir} 0770 root common-files -" ];
      systemd.services.navidrome.serviceConfig.UMask = lib.mkForce "0006";
      users.users.navidrome.extraGroups = [ "common-files" ];

      #------------------------------------------------------------------------
      # Navidrome Service
      #------------------------------------------------------------------------

      services.navidrome = {
        enable = true;
        openFirewall = false;
        group = "common-files";

        # https://www.navidrome.org/docs/usage/configuration-options/
        settings = {
          Address = params.ip;
          EnableInsightsCollector = false;
          DefaultLanguage = zone.lang;
          MusicFolder = musicDir;
          Scanner.PurgeMissing = "full";
          LastFM.Enabled = false;
          Agents = "";
        };
      };
    })
  ];
}
