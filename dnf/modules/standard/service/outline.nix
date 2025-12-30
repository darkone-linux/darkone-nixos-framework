# A full-configured outline wiki.

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
  cfg = config.darkone.service.outline;
  srvPort = 3003;
  params = dnfLib.extractServiceParams host network "outline" { };
in
{
  options = {
    darkone.service.outline.enable = lib.mkEnableOption "Enable local outline service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.outline = {
        persist.dirs = [ "/var/lib/outline" ];
        proxy.servicePort = srvPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.outline.enable = true;
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ srvPort ];
      };

      #------------------------------------------------------------------------
      # outline Service
      #------------------------------------------------------------------------

      # password
      sops.secrets.tmp-pwd = {
        mode = "0400";
        owner = "outline";
      };

      services.outline = {
        enable = true;
        publicUrl = params.href;
        port = srvPort;
        forceHttps = false;
        storage.storageType = "local";
        oidcAuthentication = {
          authUrl = "https://dex.${zone.domain}/auth";
          tokenUrl = "https://dex.${zone.domain}/token";
          userinfoUrl = "https://dex.${zone.domain}/userinfo";
          clientId = "outline";
          clientSecretFile = config.sops.secrets.tmp-pwd.path;
          scopes = [
            "openid"
            "email"
            "profile"
          ];
          usernameClaim = "preferred_username";
          displayName = "dex";
        };
      };
    })
  ];
}
