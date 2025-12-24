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

    # TODO: syncthing service ports must be open in nixos configuration
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
