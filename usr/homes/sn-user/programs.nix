{ pkgs, ... }:
{
  home.packages = with pkgs; [

    # Outils CLI
    #asciidoc-full
    #asciidoctor

    #aspellDicts.fr
    #presenterm

    # Développement, administration
    nodejs_23
    python3Full
    vscode

    # Outils Bac Pro
    #qucs-s # Schéma elec + simulation - instable
    #yed # fail
    fritzing # Simulation ne fonctionne pas
    godot_4
    klavaro
    ngspice # Simulateur elec
    qelectrotech
    rpi-imager
    simulide # TOP!

    # Education autre
    #gnome-binary # EXISTE PAS ENCORE
    #gnome-workbench # EXISTE PAS ENCORE
    #kb # Base de connaissances cli
    #kdePackages.kig # BROKEN
    #qstopmotion
    anki-bin
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
    arduino
    arduino-ide
    arduino-cli

    # Tweak
    powerline
    powerline-fonts

    # Games
    #supertuxkart
    #chessx
  ];
}
