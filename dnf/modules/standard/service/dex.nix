# A full-configured dex OIDC service.

{
  lib,
  dnfLib,
  config,
  network,
  host,
  zone,
  ...
}:
let
  cfg = config.darkone.service.dex;
  defaultParams = {
    title = "Authentication";
    description = "Global authentication for DNF services";
    icon = "dex-auth";
  };
  params = dnfLib.extractServiceParams host network "dex" defaultParams;
  srvPort = 5556;
in
{
  options = {
    darkone.service.dex.enable = lib.mkEnableOption "Enable dex service";
    darkone.service.dex.enableBootstrap = lib.mkEnableOption "Enable bootstrap state to set admin password";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.dex = {
        displayOnHomepage = false;
        inherit defaultParams;
        persist.dirs = [ "/var/lib/dex" ];
        proxy.servicePort = srvPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.dex.enable = true;
      };

      #------------------------------------------------------------------------
      # dex Service
      #------------------------------------------------------------------------

      # Main service
      services.dex = {
        enable = true;
        settings = {
          issuer = params.href;
          storage.type = "memory";
          web.http = "${params.ip}:${toString srvPort}";
          enablePasswordDB = true;
          staticClients = [
            {
              id = "forgejo-test";
              name = "Forgejo Client";
              redirectURIs = [ "https://git.${zone.domain}/user/oauth2/dex/callback" ];
              secretFile = config.sops.secrets.tmp-pwd.path;
            }
            {
              id = "outline";
              name = "Outline Client";
              redirectURIs = [ "https://outline.${zone.domain}/auth/oidc.callback" ];
              secretFile = config.sops.secrets.tmp-pwd.path;
            }
          ];
          staticPasswords = [
            {
              email = "test@${zone.domain}";
              hash = network.default.password-hash;
              username = "test";
              userID = "0ccb0be8-d515-4835-8188-a3d20bbcc3d8"; # uuidgen
            }
          ];
        };
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ srvPort ];
      };
    })
  ];
}
