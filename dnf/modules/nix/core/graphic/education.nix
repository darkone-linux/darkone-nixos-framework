# Graphical & education packages for kids

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
    darkone.graphic.education = {
      enable = lib.mkEnableOption "Default useful packages";
      enableBaby = lib.mkEnableOption "Sofwares for childs <= 6-8 yo";
      enableTeenager = lib.mkEnableOption "Sofwares for childs >= 12-14 yo";
      enableGames = lib.mkEnableOption "Additional games packages";
    };
  };

  config = lib.mkIf cfg.enable {

    # Packages
    environment.systemPackages =
      with pkgs;
      (
        # 0-6(-12) yo
        if cfg.enableBaby && !cfg.enableTeenager then
          [
            gcompris
            tuxpaint
            #tuxtype # FAIL
          ]
          ++ (if cfg.enableGames then [ rili ] else [ ])

        # 6-12 yo
        else if !cfg.enableBaby && !cfg.enableTeenager then
          [
            #childsplay (not found)
            #tuxblocs (not found)
          ]

        # (6-)12-18+ yo
        else if !cfg.enableBaby && cfg.enableTeenager then
          [
            #scratch (not found)
            #tuxmath (not found)
            avogadro2 # molecules
            geogebra6 # math
            #googleearth-pro
            klavaro
            maxima # math
            octaveFull # math
            sage # math
            scilab-bin # math
            #solfege
            verbiste
          ]
          ++ (
            if cfg.enableGames then
              [
                chessx
                stellarium
                lenmus
              ]
            else
              [ ]
          )

        # 0-18+ yo
        else
          [
            celestia
            leocad
          ]
      );

    darkone.graphic.obsidian = lib.mkIf (!cfg.enableBaby) { enable = true; };
  };
}
