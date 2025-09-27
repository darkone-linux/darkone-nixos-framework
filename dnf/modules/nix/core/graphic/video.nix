# Video creation tools.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.video;
in
{
  options = {
    darkone.graphic.video.enable = lib.mkEnableOption "Video creation (kdenlive...)";
    darkone.graphic.video.enablePro = lib.mkEnableOption "Video softwares for pros";
  };

  config = lib.mkIf cfg.enable {

    # Packages
    environment.systemPackages =
      with pkgs;
      [ kdePackages.kdenlive ] ++ (if cfg.enablePro then [ krita ] else [ ]);
  };
}
