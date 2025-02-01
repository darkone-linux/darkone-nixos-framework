{ pkgs, ... }:
{
  home.packages = with pkgs; [

    # Bureautique graphique
    hunspell
    hunspellDicts.fr-moderne
    libreoffice-fresh
    obsidian
    dialect # Outil de traduction

    # Outils CLI
    asciidoc-full
    asciidoctor
    aspellDicts.fr
    presenterm
    ranger

    # Développement, administration
    bat
    btop
    ccrypt
    duf
    findutils # locate
    nodejs_23
    python3Full
    vscode
    zellij

    # Outils Bac Pro
    fritzing
    klavaro
    ngspice # Simulateur elec
    qucs-s # Schéma elec + simulation
    qelectrotech
    godot_4
    rpi-imager

    # Productivité, multimédia
    evince
    geeqie
    gimp
    inkscape
    krita
    # yed # fail

    # Tweak
    powerline
    powerline-fonts

    # Games
    #supertuxkart
  ];
}
