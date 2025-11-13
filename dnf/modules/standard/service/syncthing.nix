# The syncthing service for a device. (WIP)
#
# :::note
# Enable the [home manager syncthing module](https://darkone-linux.github.io/ref/modules/#-darkonehomesyncthing)
# to allow users to use syncthing with their account.
# :::

{
  lib,
  config,
  host,
  network,
  ...
}:
let
  cfg = config.darkone.service.syncthing;
  srv = config.services.syncthing;
  isGateway = host.hostname == network.gateway.hostname;
  guiPort = builtins.fromJSON (builtins.elemAt (lib.splitString ":" srv.guiAddress) 1);
  lldapSettings = config.services.lldap.settings;
  #usersService = config.darkone.service.users;
  ldapBaseDn =
    "dc=" + (lib.concatStringsSep ",dc=" (builtins.match "^([^.]+)\.([^.]+)$" "${network.domain}"));
in
{
  options = {
    darkone.service.syncthing.enable = lib.mkEnableOption "Enable local syncthing service";
    darkone.service.syncthing.domainName = lib.mkOption {
      type = lib.types.str;
      default = "syncthing";
      description = "Domain name for sync server, registered in network configuration";
    };
    darkone.service.syncthing.ldapServerHost = lib.mkOption {
      type = lib.types.str;
      default = "${network.gateway.hostname}.${network.domain}";
      description = "Users service (lldap)";
    };
    darkone.service.syncthing.ldapServerPort = lib.mkOption {
      type = lib.types.str;
      default = "3890";
      description = "Users service (lldap)";
    };
  };

  config = lib.mkMerge [
    {
      # Darkone service: httpd + dnsmasq + homepage registration
      darkone.system.services.service.syncthing = {
        inherit (cfg) domainName;
        displayName = "Syncthing";
        description = "Local synchronization";
        persist.dirs = [ srv.dataDir ];
        proxy.servicePort = guiPort;
      };
    }

    (lib.mkIf cfg.enable {

      # Darkone service: enable
      darkone.system.services = {
        enable = true;
        service.syncthing.enable = true;
      };

      # Specific firewall settings for the gateway
      networking.firewall.interfaces.lan0 = lib.mkIf isGateway {
        allowedTCPPorts = [ 22000 ];
        allowedUDPPorts = [
          21027
          22000
        ];
      };

      services.syncthing = {
        enable = true;

        # Open ports for sync (not gui)
        openDefaultPorts = !isGateway;

        # Delete the devices which are not configured via the devices option
        overrideDevices = lib.mkDefault false;
        overrideFolders = lib.mkDefault false;

        # TODO
        #guiPasswordFile = "";

        settings = {
          # lib.mkIf (cfg.ldapServerHost != "") {
          gui = {
            enable = true;
            tls = false;
            theme = "black";
            # authMode = "ldap";
            user = "admin";
            password = "insecure";
            insecureAdminAccess = false;
          };

          # Folders configuration
          folders = { };

          # Devices / peers list
          devices = { };

          # Access to the interface with authorized ldap users
          ldap = lib.mkIf false {
            address = "${cfg.ldapServerHost}:${cfg.ldapServerPort}";
            bindDN = "uid=%s,ou=people,${ldapBaseDn}";
            transport = "nontls";
            insecureSkipVerify = false;
            searchBaseDN = "ou=people,${lldapSettings.ldap_base_dn}";
            searchFilter = "uid=%s";
          };

          # Additional global options
          options = {
            localAnnounceEnabled = false;
            urAccepted = -1; # no stats to syncthing.com
            relaysEnabled = true;
          };
        };
      };
    })
  ];
}
