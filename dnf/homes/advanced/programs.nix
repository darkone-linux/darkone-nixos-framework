# Useful programs for advanced users (computer scientists)

{ osConfig, pkgs, ... }:
let
  gnomeEnabled = osConfig.darkone.graphic.gnome.enable;
in
{
  home.packages = with pkgs; [
    bat
    btop
    ccrypt
    dig
    dos2unix
    duf
    gawk
    htop
    jq
    lsof
    microfetch
    pciutils # lspci pcilmr setpci
    psmisc # killall, pstree, pslog, fuser...
    pv
    ranger
    rename
    rsync
    strace
    zellij
  ];

  # Zed editor
  darkone.home.zed.enable = gnomeEnabled;
}
