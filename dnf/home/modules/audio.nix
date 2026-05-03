# Audio tools and effects.
#
# Installs an audio player (`vlc`) and the MP3 encoder (`lame`)
# unconditionally, then layers editors and effects (`audacity`,
# `easyeffects` with the `easyeffects-fw16` preset) when `enableTools` is
# set. Real-time noise reduction (`noisetorch`) is intentionally disabled
# because it requires PulseAudio.

{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.darkone.home.audio;
in
{
  options = {
    darkone.home.audio.enable = lib.mkEnableOption "Audio tools";
    darkone.home.audio.enableTools = lib.mkEnableOption "Audio tools / editors (audacity, easyeffect, noisetorch...)";
  };

  # TODO: to complete
  config = lib.mkIf cfg.enable {

    # Nix packages
    home.packages = with pkgs; [
      #(lib.mkIf cfg.enableTools noisetorch) # Realtime noise reduction (pulseaudio only)
      (lib.mkIf cfg.enableTools audacity)
      lame
      vlc
    ];

    # https://github.com/wwmm/easyeffects
    services.easyeffects = lib.mkIf cfg.enableTools {
      enable = true;
      preset = "easyeffects-fw16";
    };
  };
}
