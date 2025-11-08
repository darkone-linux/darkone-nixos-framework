# LLDAP service for DNF SSO.

{
  lib,
  config,
  network,
  ...
}:
let
  cfg = config.darkone.service.users;
  lldapSettings = config.services.lldap.settings;
  lldapUserDn = "admin";
in
{
  options = {
    darkone.service.users.enable = lib.mkEnableOption "Enable local user management with LLDAP (SSO)";
    darkone.service.users.domainName = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Domain name for user management (SSO), registered in network configuration";
    };
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.users = {
        inherit (cfg) domainName;
        displayName = "Users";
        description = "Global user management for DNF services";
        icon = "openldap";
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
          http_host = "localhost";
          ldap_host = cfg.domainName;
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
