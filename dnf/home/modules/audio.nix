# Audio tools.

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
    ];

    # https://github.com/wwmm/easyeffects
    services.easyeffects = lib.mkIf cfg.enableTools {
      enable = true;
      preset = "easyeffects-fw16";
    };
  };
}
