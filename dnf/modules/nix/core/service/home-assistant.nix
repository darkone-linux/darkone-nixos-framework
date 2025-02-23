{ lib, config, ... }:
let
  cfg = config.darkone.service.home-assistant;
in
{
  options = {
    darkone.service.home-assistant.enable = lib.mkEnableOption "Enable home assitant";
  };

  config = lib.mkIf cfg.enable {

    # HA default service configuration
    # TODO: complete the configuration
    services.home-assistant = {
      enable = true;
      extraComponents = [
        #"esphome"
        #"met"
        "sun"
        "met"
        "supervisord"
        "bluetooth"
        "mqtt"
        "radio_browser"
      ];
      config = {

        # TODO: Includes dependencies for a basic setup
        # https://www.home-assistant.io/integrations/default_config/
        default_config = { };
      };
    };
    networking.firewall.allowedTCPPorts = [ 8123 ];
  };
}
