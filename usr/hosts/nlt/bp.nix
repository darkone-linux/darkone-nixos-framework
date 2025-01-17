# Specific modules for students

{ ... }:
{
  # HA
  services.home-assistant = {
    enable = true;
    extraComponents = [
      # Components required to complete the onboarding
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
      # Includes dependencies for a basic setup
      # https://www.home-assistant.io/integrations/default_config/
      default_config = { };
    };
  };
  networking.firewall.allowedTCPPorts = [ 8123 ];
}
