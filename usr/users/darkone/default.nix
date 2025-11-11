# Specific home manager settings for user darkone id:1000 (darkone@darkone.yt)

{ osConfig, pkgs, ... }:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
in
{
  home.username = "darkone"; # DO NOT TOUCH!
  home.stateVersion = "25.05"; # DO NOT TOUCH!

  # My binaries
  home.sessionPath = [ "$HOME/bin" ];

  # DNF home modules
  darkone.home = {
    music = {
      enable = true;
      enableCli = true;
      enableFun = graphic;
      enableDev = graphic;
      enableScore = graphic;
      enableBeginner = graphic;
    };
    games.enableTeenager = graphic;
    office = {
      enable = graphic;
      enableBrave = true;
      enableEmail = true;
      enableCommunication = true;
      enableCalendarContacts = true;
    };
    imagery = {
      enable = true;
      enablePro = true;
      enableCAD = true;
    };
    video = {
      enable = true;
      enableTools = true;
      enableEditing = true;
      enableCreator = true;
    };
  };

  # Specific packages
  home.packages = with pkgs; [
    asciidoc-full
    asciidoctor
    aspellDicts.fr
    kdePackages.kdenlive
    mattermost-desktop
    opencpn
    viking
  ];
}
