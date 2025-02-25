# Children profile programs

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    avogadro2
    celestia
    chessx
    gcompris
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
    leocad
    solfege
    stellarium
    tuxpaint
    verbiste
    wike
  ];
}
