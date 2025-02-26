# Teenager profile programs

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    #scilab-bin # math (ERR)
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
    lmms
    maxima # math
    mixxx
    muse-sounds-manager
    musescore
    octaveFull # math
    sage # math
    solfege
    soundfont-fluid
    stellarium
    tuxpaint
    verbiste
    wike
  ];
}
