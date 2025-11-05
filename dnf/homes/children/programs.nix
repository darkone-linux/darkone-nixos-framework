# Children profile programs

{ pkgs, lib, ... }:
{
  darkone.home.games.enableChildren = lib.mkDefault osConfig.darkone.graphic.gnome.enable;

  home.packages = with pkgs; [
    avogadro2
    celestia

    #gcompris # TODO: fail
    geogebra6
    gnome-maps
    kdePackages.blinken # Entrainement de la mémoire
    kdePackages.kalzium # Tableau périodique
    kdePackages.kgeography # Apprentissage de la géographie
    kdePackages.kmplot # Maths
    kdePackages.kturtle # LOGO
    kdePackages.parley # Vocabulaire
    klavaro
    lenmus

    solfege

    verbiste
    wike
  ];
}
