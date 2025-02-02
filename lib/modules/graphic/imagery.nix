# MAO

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.imagery;
in
{
  options = {
    darkone.graphic.imagery = {
      enable = lib.mkEnableOption "Imagery creation";
      enablePro = lib.mkEnableOption "Image softwares for pros";
    };
  };

  config = lib.mkIf cfg.enable {

    # Packages
    environment.systemPackages =
      with pkgs;
      [
        evince
        geeqie
        gimp
        inkscape
        pinta
        kdePackages.kdenlive
        krita
      ]
      ++ (if cfg.enablePro then [ blender ] else [ ]);
  };
}
