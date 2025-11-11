# Several graphical education packages.

{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.darkone.home.education;
in
{
  options = {
    darkone.home.education.enableBaby = lib.mkEnableOption "Education software for babies (<=6 yo)";
    darkone.home.education.enableChild = lib.mkEnableOption "Education software for children (6-12 yo)";
    darkone.home.education.enableStudent = lib.mkEnableOption "Education software for teenagers and adults (>=12 yo)";
    darkone.home.education.enableMath = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Math tools and apps";
    };
    darkone.home.education.enableMusic = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Music tools and apps";
    };
    darkone.home.education.enableScience = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Scientific tools and apps";
    };
    darkone.home.education.enableDraw = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Draw tools and apps";
    };
    darkone.home.education.enableLang = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Lang tools and apps";
    };
    darkone.home.education.enableMisc = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Misc tools and apps (general, training...)";
    };
    darkone.home.education.enableComputer = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Computing tools and apps (klavaro, etc.)";
    };
  };

  config = lib.mkIf (cfg.enableBaby || cfg.enableChild || cfg.enableStudent) {

    # Packages
    home.packages = with pkgs; [
      #(lib.mkIf (cfg.enableMisc && (cfg.enableBaby || cfg.enableChild)) gcompris) # COMPILATION FAILED
      (lib.mkIf (cfg.enableComputer && (cfg.enableChild || cfg.enableStudent)) kdePackages.kturtle) # logo
      (lib.mkIf (cfg.enableComputer && (cfg.enableChild || cfg.enableStudent)) klavaro)
      (lib.mkIf (cfg.enableLang && (cfg.enableChild || cfg.enableStudent)) kdePackages.parley) # vocabulary
      (lib.mkIf (cfg.enableLang && (cfg.enableChild || cfg.enableStudent)) verbiste)
      (lib.mkIf (cfg.enableMath && (cfg.enableChild || cfg.enableStudent)) geogebra6) # math
      (lib.mkIf (cfg.enableMath && (cfg.enableChild || cfg.enableStudent)) kdePackages.kmplot) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) gnome-graphs)
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) kdePackages.cantor) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) kdePackages.kalgebra) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) kdePackages.kbruch) # fractions
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) labplot) # data visualization
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) maxima) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) maxima) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) octaveFull) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) octaveFull) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) sage) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) sage) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) scilab-bin) # math
      (lib.mkIf (cfg.enableMisc && (cfg.enableChild || cfg.enableStudent)) kdePackages.blinken) # memory training
      (lib.mkIf (cfg.enableMisc && (cfg.enableChild || cfg.enableStudent)) wike) # wikipedia
      (lib.mkIf (cfg.enableMusic && (cfg.enableBaby || cfg.enableChild)) tuxpaint)
      (lib.mkIf (cfg.enableMusic && (cfg.enableChild || cfg.enableStudent)) solfege)
      (lib.mkIf (cfg.enableScience && (cfg.enableChild || cfg.enableStudent)) avogadro2) # molecules
      (lib.mkIf (cfg.enableScience && (cfg.enableChild || cfg.enableStudent)) celestia)
      (lib.mkIf (cfg.enableScience && (cfg.enableChild || cfg.enableStudent)) gnome-maps)
      (lib.mkIf (cfg.enableScience && (cfg.enableChild || cfg.enableStudent)) kdePackages.kalzium) # periodic elements
      (lib.mkIf (cfg.enableScience && (cfg.enableChild || cfg.enableStudent)) kdePackages.kgeography) # geography
      (lib.mkIf (cfg.enableScience && (cfg.enableChild || cfg.enableStudent)) atomix) # Atom puzzle
    ];
  };
}
