# Image processing softwares (gimp, geeqie, pinta + blender, inkscape, krita...).

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.home.imagery;
in
{
  options = {
    darkone.home.imagery.enable = lib.mkEnableOption "Imagery creation";
    darkone.home.imagery.enablePro = lib.mkEnableOption "Additional image processing software for professionals";
    darkone.home.imagery.enableBeginner = lib.mkEnableOption "Additional image processing software for beginners";
    darkone.home.imagery.enable3D = lib.mkEnableOption "3D softwares";
    darkone.home.imagery.enableCAD = lib.mkEnableOption "CAD softwares";
  };

  config = lib.mkIf cfg.enable {

    # Packages
    home.packages = with pkgs; [
      geeqie
      gimp
      (lib.mkIf cfg.enableBeginner pinta)
      (lib.mkIf (cfg.enablePro && cfg.enable3D) blender)
      (lib.mkIf cfg.enablePro inkscape)
      (lib.mkIf cfg.enablePro krita)
      (lib.mkIf cfg.enablePro yed)
    ];
  };
}
