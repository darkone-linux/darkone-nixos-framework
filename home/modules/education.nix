# Several graphical education packages.

{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.darkone.home.education;

  # Audiences sharing a package
  babyOrChild = cfg.enableBaby || cfg.enableChild;
  childOrStudent = cfg.enableChild || cfg.enableStudent;
in
{
  options = {
    darkone.home.education.enable = lib.mkEnableOption "Education software collection";

    # By profile (default false)
    darkone.home.education.enableBaby = lib.mkEnableOption "Education software for babies (<=6 yo)";
    darkone.home.education.enableChild = lib.mkEnableOption "Education software for children (6-12 yo)";
    darkone.home.education.enableStudent = lib.mkEnableOption "Education software for teenagers and adults (>=12 yo)";

    # By theme (default true)
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

  config = lib.mkIf cfg.enable {

    # Packages
    home.packages = with pkgs; [
      #(lib.mkIf (cfg.enableMisc && childOrStudent) wike) # Wikipedia reader, too heavy
      (lib.mkIf (cfg.enableComputer && childOrStudent) kdePackages.kturtle) # logo
      (lib.mkIf (cfg.enableComputer && childOrStudent) klavaro)
      (lib.mkIf (cfg.enableLang && childOrStudent) kdePackages.parley) # vocabulary
      (lib.mkIf (cfg.enableLang && childOrStudent) verbiste)
      (lib.mkIf (cfg.enableLang && childOrStudent) gnome-characters)
      (lib.mkIf (cfg.enableMath && childOrStudent) geogebra) # math (note: geogebra6 -> build fail, current is 5)
      (lib.mkIf (cfg.enableMath && childOrStudent) kdePackages.kmplot) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) gnome-graphs)
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) kdePackages.cantor) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) kdePackages.kalgebra) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) kdePackages.kbruch) # fractions
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) labplot) # data visualization
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) maxima) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) octaveFull) # math
      (lib.mkIf (cfg.enableMath && cfg.enableStudent) scilab-bin) # math
      (lib.mkIf (cfg.enableMisc && babyOrChild) gcompris)
      (lib.mkIf (cfg.enableMisc && cfg.enableChild) kdePackages.blinken) # memory training
      (lib.mkIf (cfg.enableMisc && cfg.enableStudent) anki) # training cards
      (lib.mkIf (cfg.enableMusic && babyOrChild) tuxpaint)
      (lib.mkIf (cfg.enableMusic && childOrStudent) solfege)
      (lib.mkIf (cfg.enableScience && childOrStudent) atomix) # Atom puzzle
      (lib.mkIf (cfg.enableScience && childOrStudent) gnome-maps)
      (lib.mkIf (cfg.enableScience && childOrStudent) kdePackages.kalzium) # periodic elements
      (lib.mkIf (cfg.enableScience && childOrStudent) kdePackages.kgeography) # geography
      (lib.mkIf (cfg.enableScience && childOrStudent) avogadro2) # molecules
      (lib.mkIf (cfg.enableDraw && childOrStudent) pencil2d)
      (lib.mkIf (cfg.enableDraw && childOrStudent) synfigstudio)
      (lib.mkIf (cfg.enableDraw && childOrStudent) ffmpeg) # Synfig dependency
    ];
  };
}
