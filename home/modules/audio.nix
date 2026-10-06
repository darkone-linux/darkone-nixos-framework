# Audio tools and effects.
#
# Installs the MP3 encoder (`lame`) and, with GNOME, an audio player
# (`vlc`), then layers editors and effects (`audacity`, `easyeffects`) when
# `enableTools` is set. Real-time noise reduction (`noisetorch`) is
# intentionally disabled because it requires PulseAudio.

{
  pkgs,
  lib,
  config,
  osConfig,
  ...
}:

let
  cfg = config.darkone.home.audio;
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  options = {
    darkone.home.audio.enable = lib.mkEnableOption "Audio tools";
    darkone.home.audio.enableTools = lib.mkEnableOption "Audio tools / editors (audacity, easyeffects)";
  };

  config = lib.mkIf cfg.enable {

    # Nix packages
    home.packages = with pkgs; [
      #(lib.mkIf cfg.enableTools noisetorch) # Realtime noise reduction (pulseaudio only)
      (lib.mkIf cfg.enableTools audacity)
      lame
      (lib.mkIf graphic vlc)
    ];

    # https://github.com/wwmm/easyeffects
    services.easyeffects = lib.mkIf cfg.enableTools { enable = true; };
  };
}
