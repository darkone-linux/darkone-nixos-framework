# Netdata supervision module.

{
  lib,
  config,
  pkgs,
  host,
  ...
}:
let
  cfg = config.darkone.service.netdata;
in
{
  options = {
    darkone.service.netdata.enable = lib.mkEnableOption "Enable netdata application";
    darkone.service.netdata.domainName = lib.mkOption {
      type = lib.types.str;
      default = "netdata";
      description = "Domain name for netdata, registered in nginx & hosts";
    };
  };

  config = lib.mkIf cfg.enable {

    # Virtualhost for netdata
    services.nginx = {
      enable = lib.mkForce true;
      virtualHosts.${cfg.domainName} = {
        extraConfig = ''
          client_max_body_size 512M;
        '';
        locations."/".proxyPass = "http://localhost:19999";
      };
    };

    # Add netdata domain to /etc/hosts
    networking.hosts."${host.ip}" = lib.mkIf config.services.dnsmasq.enable [ "${cfg.domainName}" ];

    # Add netdata in Administration section of homepage
    darkone.service.homepage.adminServices = [
      {
        "netdata" = {
          description = "Outil de supervision";
          href = "http://${cfg.domainName}";
          icon = "sh-netdata";
        };
      }
    ];

    #networking.firewall.allowedTCPPorts = [ 19999 ];
    services.netdata = {
      enable = true;
      config = {
        global = {
          "memory mode" = "ram";
          "debug log" = "none";
          "access log" = "none";
          "error log" = "syslog";
        };
      };
    };

    nixpkgs.config.allowUnfree = true;
    services.netdata.package = pkgs.netdata.override { withCloudUi = true; };
  };
}
