{ pkgs, ... }:
{
  # Additional programs
  home.packages = with pkgs; [

    # Outils CLI
    #asciidoc-full
    #asciidoctor
    #aspellDicts.fr
    #presenterm

    # Education autre
    #kdePackages.kig # BROKEN
    #qstopmotion
    #cantor # Outil puissant pour les maths et les stats
    #gaphor # UML
    #geogebra6
    #gnome-graphs
    #gnome-maps
    #kdePackages.blinken # Entrainement de la mémoire
    #kdePackages.isoimagewriter
    #kdePackages.kalgebra # Outil mathématique
    #kdePackages.kalzium # Tableau périodique
    #kdePackages.kbruch # Exercices fractions
    #kdePackages.kgeography # Apprentissage de la géographie
    #kdePackages.kmplot # Maths
    #kdePackages.kturtle # LOGO
    #kdePackages.parley # Vocabulaire
    #kdePackages.step
    #labplot
    #super-productivity
    #textpieces # Couteau suisse chiffrage, text-processing
    #tuba # fediverse
    #wike # wikipedia

    # Arduino
    #arduino
    #arduino-ide
    #arduino-cli

    # Web
    sqlite
    sqlite-web
    sqlite-utils
    sqlitebrowser
    php84Extensions.sqlite3

    # Outils spécifiques TSN
    pixelorama

    # Games
    superTuxKart
    #chessx
  ];
}
