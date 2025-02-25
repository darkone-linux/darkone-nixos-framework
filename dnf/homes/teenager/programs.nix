# Teenager profile programs

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    avogadro2 # molecules
    cantor
    celestia
    chessx
    geogebra6 # math
    gnome-maps
    kdePackages.blinken # Entrainement de la mémoire
    kdePackages.kalgebra # Outil mathématique
    kdePackages.kalzium # Tableau périodique
    kdePackages.kbruch # Exercices fractions
    kdePackages.kgeography # Apprentissage de la géographie
    kdePackages.kmplot # Maths
    kdePackages.kturtle # LOGO
    kdePackages.parley # Vocabulaire
    klavaro
    labplot
    lenmus
    leocad
    maxima # math
    octaveFull # math
    sage # math
    #scilab-bin # math (ERR)
    solfege
    stellarium
    stellarium
    verbiste
    wike
  ];
}
