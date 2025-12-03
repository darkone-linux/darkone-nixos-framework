# LLDAP service for DNF SSO.

{
  lib,
  dnfLib,
  config,
  network,
  host,
  ...
}:
let
  cfg = config.darkone.service.users;
  lldapSettings = config.services.lldap.settings;
  lldapUserDn = "admin";
  defaultParams = {
    description = "Global user management for DNF services";
    icon = "openldap";
  };
  params = dnfLib.extractServiceParams host network "users" defaultParams;
in
{
  options = {
    darkone.service.users.enable = lib.mkEnableOption "Enable local user management with LLDAP (SSO)";
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.users = {
        inherit defaultParams;
        persist.dirs = [ "/var/lib/lldap" ];
        proxy.servicePort = lldapSettings.http_port; # Default is 17170
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.users.enable = true;
      };

      # Access to default password
      users.users.lldap = {
        isSystemUser = true;
        group = "lldap";
        extraGroups = [ "sops" ];
      };
      users.groups.lldap = { };

      # Main service
      services.lldap = {
        enable = true;
        settings = {
          http_host = params.ip;
          ldap_host = params.fqdn;
          ldap_user_dn = lldapUserDn;
          ldap_user_email = "${lldapUserDn}@${network.domain}";
          ldap_user_pass_file = config.sops.secrets.default-password.path;
          force_ldap_user_pass_reset = "always";
          ldap_base_dn =
            "dc=" + (lib.concatStringsSep ",dc=" (builtins.match "^([^.]+)\.([^.]+)$" "${network.domain}"));
        };
      };

      # Ldap access to local network
      networking.firewall.interfaces.lan0.allowedTCPPorts = [ lldapSettings.ldap_port ];
    })
  ];
}
