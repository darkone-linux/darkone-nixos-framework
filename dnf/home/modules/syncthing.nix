# Home sync module. (WIP)

{
  lib,
  config,
  osConfig,
  user,
  ...
}:
let
  cfg = config.darkone.home.syncthing;
  #isGateway = host.hostname == network.gateway.hostname;
in
{
  options = {
    darkone.home.syncthing.enable = lib.mkEnableOption "Enable local syncthing service";
    darkone.home.syncthing.enableTray = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable syncthing tray app / icon";
    };
  };

  config = lib.mkIf cfg.enable {

    # Specific firewall settings for the gateway
    # osConfig.networking.firewall.interfaces.lan0 = lib.mkIf isGateway {
    #   allowedTCPPorts = [ 22000 ];
    #   allowedUDPPorts = [
    #     21027
    #     22000
    #   ];
    # };

    services.syncthing = {
      enable = true;

      # Delete the devices which are not configured via the devices option
      overrideDevices = lib.mkDefault false;
      overrideFolders = lib.mkDefault false;

      # Account password of current user
      passwordFile = osConfig.sops.secrets."user/${user.username}/password-hash".path;

      # syncthingtray-minimal
      tray.enable = cfg.enableTray;

      settings = {
        gui = {
          enable = true;
          tls = false;
          user = "${user.usename}";
          insecureAdminAccess = false;
        };

        # Folders configuration
        folders = { };

        # Devices / peers list
        devices = { };

        # Additional global options
        options = {
          localAnnounceEnabled = false;
          urAccepted = -1; # no stats to syncthing.com
        };
      };
    };
  };
}
