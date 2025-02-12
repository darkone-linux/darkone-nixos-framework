{ pkgs, ... }:
{
  home.packages = with pkgs; [

    # Outils CLI
    asciidoc-full
    asciidoctor
    aspellDicts.fr
    ccrypt
    duf
    htop
    presenterm
    ranger
    zellij

    # Développement, administration
    gparted
    jetbrains.idea-ultimate
    nodejs_23
    python3Full
    vscode

    # Réseau
    #nettools
    filezilla
    nmap

    # Productivité, multimédia
    evince
    geeqie
    gimp
    inkscape
    super-productivity
    yed

    # Tweak
    powerline
    powerline-fonts

    # TODO
    #gpsd
    #kdePackages.kdenlive
    #opencpn
    #programs.obs-studio.enable = true; # cf. plugins
    #telegram-desktop
    #viking
    #whatsapp-for-linux
  ];

  services.easyeffects = {
    enable = true;
    preset = "easyeffects-fw16";
  };
}
