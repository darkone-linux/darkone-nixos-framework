{ pkgs, ... }:
{
  home.packages = with pkgs; [

    # Bureautique graphique
    hunspell
    hunspellDicts.fr-moderne
    libreoffice-fresh
    obsidian

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

    # Productivité, multimédia
    evince
    geeqie
    gimp
    inkscape
    krita

    # Tweak
    powerline
    powerline-fonts

    # Games
    #supertuxkart
  ];
}
