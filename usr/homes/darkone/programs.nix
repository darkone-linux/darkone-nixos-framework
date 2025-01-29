{ pkgs, ... }:
{
  home.packages = with pkgs; [

    # Bureautique graphique
    #ghostscript
    #gv
    #thunderbird
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
    gparted
    nodejs_23
    python3Full
    vscode
    zellij
    jetbrains.idea-ultimate

    # Réseau
    #nettools
    filezilla
    nmap

    # Outils Bac Pro
    fritzing
    klavaro
    ngspice # Simulateur elec
    qucs-s # Schéma elec + simulation

    # Productivité, multimédia
    evince
    geeqie
    gimp
    inkscape
    super-productivity

    # Tweak
    powerline
    powerline-fonts

    # TODO
    #viking
    #opencpn
    #whatsapp-for-linux
    #telegram-desktop
    #kdePackages.kdenlive
    #programs.obs-studio.enable = true; # cf. plugins
    #gpsd
  ];
}
