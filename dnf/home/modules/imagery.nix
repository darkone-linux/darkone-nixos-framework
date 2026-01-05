# Image processing softwares (gimp, geeqie, pinta + blender, inkscape, krita...).

{
  lib,
  config,
  pkgs,
  pkgs-stable,
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
    darkone.home.imagery.enableCli = lib.mkEnableOption "CLI tools (imagemagick, jhead...)";
  };

  config = lib.mkIf cfg.enable {

    # Packages
    home.packages = with pkgs; [
      geeqie
      gimp
      (lib.mkIf cfg.enableBeginner pinta)
      (lib.mkIf cfg.enableCli imagemagick)
      (lib.mkIf cfg.enableCli jhead)
      (lib.mkIf (cfg.enablePro && cfg.enable3D) blender)
      (lib.mkIf cfg.enablePro inkscape)
      (lib.mkIf cfg.enablePro krita)
      (lib.mkIf cfg.enablePro yed)
      (lib.mkIf cfg.enableCAD pkgs-stable.freecad)
    ];
  };
}
