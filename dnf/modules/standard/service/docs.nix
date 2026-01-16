# A full-configured lasuite-docs module.

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
  cfg = config.darkone.service.docs;
  srvPort = 8000;
  params = dnfLib.extractServiceParams host network "docs" { };
in
{
  options = {
    darkone.service.docs.enable = lib.mkEnableOption "Enable local docs service";
  };

  config = lib.mkMerge [

    #------------------------------------------------------------------------
    # DNF Service configuration
    #------------------------------------------------------------------------

    {
      darkone.system.services.service.docs = {
        persist.dirs = [ "/var/lib/lasuite-docs" ];
        proxy.servicePort = srvPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.docs.enable = true;
      };

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = lib.setAttrByPath (dnfLib.getInternalInterfaceFwPath host zone) {
        allowedTCPPorts = lib.mkIf (!dnfLib.isGateway host zone) [ srvPort ];
      };

      #------------------------------------------------------------------------
      # docs Service
      #------------------------------------------------------------------------

      # password
      # TODO: déclaration dans IDM
      sops.secrets.oidc-secret-lasuite-docs = {
        mode = "0400";
        owner = "lasuite-docs";
        key = "oidc-secret-docs";
      };

      services.lasuite-docs = {
        enable = true;
        enableNginx = false;
        domain = params.fqdn;
        redis.createLocally = true;
        postgresql.createLocally = true;
        environmentFile = "";
        settings = {
          LANGUAGE_CODE = zone.lang;
        };
      };
    })
  ];
}
