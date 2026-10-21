# Image processing software.
#
# Always installs the editor (`gimp`); the viewer (`geeqie`) is one of the
# office essentials. Then layers tooling by audience: `enableBeginner` adds
# `pinta`, `enablePro` adds `inkscape`/`krita`/`yed`, `enable3D` (with
# `enablePro`) adds `blender`, `enableCAD` adds `freecad`, and `enableCli`
# adds `imagemagick`/`jhead`.

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
    darkone.home.imagery.enableCli = lib.mkEnableOption "CLI tools (imagemagick, jhead...)";
  };

  config = lib.mkIf cfg.enable {

    # Packages
    home.packages = with pkgs; [
      gimp
      (lib.mkIf cfg.enableBeginner pinta)
      (lib.mkIf cfg.enableCli imagemagick)
      (lib.mkIf cfg.enableCli jhead)
      (lib.mkIf (cfg.enablePro && cfg.enable3D) blender)
      (lib.mkIf cfg.enablePro inkscape)
      (lib.mkIf cfg.enablePro krita)
      (lib.mkIf cfg.enablePro yed)
      (lib.mkIf cfg.enablePro pixelorama) # Pixel art, sprites
      (lib.mkIf cfg.enableCAD freecad)
      (lib.mkIf cfg.enableCAD sweethome3d.application) # Interior design
    ];
  };
}
