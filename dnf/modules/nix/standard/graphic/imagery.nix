# Image processing softwares (gimp, geeqie, pinta + blender, inkscape, krita...).

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
    darkone.graphic.imagery.enable = lib.mkEnableOption "Imagery creation";
    darkone.graphic.imagery.enablePro = lib.mkEnableOption "Additional image processing software for professionals";
  };

  config = lib.mkIf cfg.enable {

    # Packages
    environment.systemPackages =
      with pkgs;
      [
        geeqie
        gimp
        pinta
      ]
      ++ (
        if cfg.enablePro then
          [
            blender
            inkscape
            krita
          ]
        else
          [ ]
      );
  };
}
