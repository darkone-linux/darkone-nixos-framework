# Opencloud full-configured service (wip - not working).

{
  lib,
  config,
  network,
  host,
  dnfLib,
  ...
}:
let
  cfg = config.darkone.service.opencloud;
  srv = config.services.opencloud;
  defaultParams = {
    description = "Local personal cloud";
  };
  params = dnfLib.extractServiceParams host network "opencloud" defaultParams;
in
{
  options = {
    darkone.service.opencloud.enable = lib.mkEnableOption "Enable local opencloud service";
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.opencloud = {
        inherit defaultParams;
        persist = {
          dirs = [ srv.stateDir ];
        };
        proxy.scheme = "https";
        proxy.servicePort = srv.port;
        proxy.extraConfig = ''
          {
            transport http {
              tls_insecure_skip_verify
            }
          }
        '';
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.opencloud.enable = true;
      };

      networking.firewall.allowedTCPPorts = [ srv.port ];

      # Nextcloud main service
      services.opencloud = {
        enable = true;
        url = params.href;
        address = "0.0.0.0"; # params.ip;
        #group = "common-files";
        environment = {
          OC_INSECURE = "true";
          OC_LOG_LEVEL = "error";
          OC_DOMAIN = params.fqdn;
          INITIAL_ADMIN_PASSWORD = "changme";
          IDM_ADMIN_PASSWORD = "changme";
        };
      };
    })
  ];
}
