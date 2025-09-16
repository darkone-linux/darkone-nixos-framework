# Teenager profile programs

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    #scilab-bin # math (ERR)
    avogadro2 # molecules
    celestia
    chessx
    geogebra6 # math
    gnome-maps
    kdePackages.blinken # Entrainement de la mémoire
    kdePackages.cantor
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
    #lmms # Erreur de compilation avec pyliblo3 + overide python 312 ne fonctionne pas
    maxima # math
    mixxx
    muse-sounds-manager
    musescore
    octaveFull # math
    #sage # math
    solfege
    soundfont-fluid
    stellarium
    tuxpaint
    verbiste
    wike
  ];
}
