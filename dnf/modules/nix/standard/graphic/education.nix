# Graphical education packages.
#
# :::note
# These programs are installed for all user profiles.
# To ensure each user has software that matches their profile (baby, child, teenager, student, etc.), use HomeManager profiles.
# :::

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.graphic.education;
in
{
  options = {
    darkone.graphic.education.enable = lib.mkEnableOption "Default useful packages";
    darkone.graphic.education.enableBaby = lib.mkEnableOption "Software for babies (<=6 yo)";
    darkone.graphic.education.enableChildren = lib.mkEnableOption "Software for children (6-12 yo)";
    darkone.graphic.education.enableTeenager = lib.mkEnableOption "Software for teenagers and adults (>=12 yo)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages =
      with pkgs;
      (
        # (lib.mkIf cfg.enableBaby tuxpaint) # Fail
        # (lib.mkIf cfg.enableChildren childsplay) # Not found
        # (lib.mkIf cfg.enableChildren tuxblocs) # Not found
        # (lib.mkIf cfg.enableTeenager scratch) # Not found
        # (lib.mkIf cfg.enableTeenager tuxmath) # Not found
        (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) avogadro2) # molecules
          (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) celestia) # Not found
          (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) inkscape)
          (lib.mkIf (cfg.enableChildren || cfg.enableTeenager) solfege)
          (lib.mkIf cfg.enableBaby gcompris)
          (lib.mkIf cfg.enableBaby tuxpaint)
          (lib.mkIf cfg.enableTeenager geogebra6) # math
          (lib.mkIf cfg.enableTeenager maxima) # math
          (lib.mkIf cfg.enableTeenager octaveFull) # math
          (lib.mkIf cfg.enableTeenager sage) # math
          (lib.mkIf cfg.enableTeenager scilab-bin) # math
          (lib.mkIf cfg.enableTeenager super-productivity)
          (lib.mkIf cfg.enableTeenager verbiste)
          (lib.mkIf cfg.enableTeenager yed)
      );

    darkone.graphic.obsidian = lib.mkIf (cfg.enableChildren || cfg.enableTeenager) { enable = true; };
  };
}
