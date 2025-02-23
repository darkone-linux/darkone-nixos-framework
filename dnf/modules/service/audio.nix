{ lib, config, ... }:
let
  cfg = config.darkone.service.audio;
in
{
  options = {
    darkone.service.audio.enable = lib.mkEnableOption "Enable sound system";
  };

  config = lib.mkIf cfg.enable {

    # Whether to enable the RealtimeKit system service, which hands out realtime scheduling
    # priority to user processes on demand. PipeWire use this to acquire realtime priority.
    #security.rtkit.enable = true;

    # Enable sound with pipewire.
    services.pulseaudio.enable = false;
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;

      # TODO If you want to use JACK applications, uncomment this
      #jack.enable = true;

      # use the example session manager (no others are packaged yet so this is enabled by default,
      # no need to redefine it in your config for now)
      #media-session.enable = true;
    };
  };
}
