# Pre-configured lldap configuration for users and groups.

{
  lib,
  host,
  config,
  network,
  ...
}:
let
  cfg = config.darkone.service.lldap;
  srv = config.services.lldap.settings;
in
{
  options = {
    darkone.service.lldap.enable = lib.mkEnableOption "Enable local lldap service";
    darkone.service.lldap.openLdapPort = lib.mkEnableOption "Open the lldap port (default is 3890)";
    darkone.service.lldap.domainName = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Domain name for lldap, registered in forgejo, nginx & hosts";
    };
  };

  config = lib.mkIf cfg.enable {

    # Virtualhost for forgejo
    # Note: default http_port for lldap is 17170
    services.nginx = {
      enable = lib.mkForce true;
      virtualHosts.${cfg.domainName} = {
        extraConfig = ''
          client_max_body_size 512M;
        '';
        locations."/".proxyPass = "http://localhost:${toString srv.http_port}";
      };
    };

    # Add lldap domain to /etc/hosts
    networking.hosts."${host.ip}" = lib.mkIf config.services.dnsmasq.enable [ "${cfg.domainName}" ];

    # Main service
    services.lldap = {
      enable = true;
      settings = {
        http_host = "localhost";
        ldap_host = "${cfg.domainName}";
        ldap_user_email = "${srv.ldap_user_dn}@${network.domain}";
        ldap_base_dn =
          "dc=" + (lib.concatStringsSep ",dc=" (builtins.match "^([^.]+)\.([^.]+)$" "${network.domain}"));
      };
    };

    # Open LLDAP in local network (not required by default)
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openLdapPort [ srv.ldap_port ];
  };
}
