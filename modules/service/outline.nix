# A full-configured outline wiki.

{
  lib,
  dnfLib,
  config,
  network,
  zone,
  host,
  hosts,
  ...
}:
let
  cfg = config.darkone.service.outline;
  srvPort = 3003;
  params = dnfLib.extractServiceParams host network "outline" { };
  inherit
    (dnfLib.mkOidcContext {
      name = "outline";
      inherit params network hosts;
    })
    clientId
    secret
    idmUrl
    ;
  oidc = dnfLib.mkKanidmEndpoints idmUrl clientId;
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

      # Kanidm OAuth2 client template
      darkone.service.idm.oauth2.outline = {
        displayName = "Outline Documentation";
        imageFile = ./../../assets/app-icons/outline.svg;
        redirectPaths = [ "/auth/oidc.callback" ];
        landingPath = "/";
        allowInsecureClientDisablePkce = true;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = dnfLib.enableBlock "outline";

      #------------------------------------------------------------------------
      # Firewall
      #------------------------------------------------------------------------

      networking.firewall = dnfLib.mkInternalFirewall host zone [ srvPort ];

      #------------------------------------------------------------------------
      # outline Service
      #------------------------------------------------------------------------

      # Re-encrypted alias of the kanidm-owned OAuth2 secret, readable by the
      # outline user (sops `key` field unmaps the master secret name).
      sops.secrets."${secret}-service" = {
        mode = "0400";
        owner = "outline";
        key = secret;
      };

      services.outline = {
        enable = true;
        publicUrl = params.href;
        port = srvPort;
        forceHttps = false;
        storage.storageType = "local";
        oidcAuthentication = {
          inherit (oidc) authUrl tokenUrl userinfoUrl;
          inherit clientId;
          clientSecretFile = config.sops.secrets."${secret}-service".path;
          displayName = "idm";
        };
      };
    })
  ];
}
