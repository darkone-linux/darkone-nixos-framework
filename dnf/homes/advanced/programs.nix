# Useful programs for advanced users (computer scientists)

{ pkgs, ... }:
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
    iw
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
    wirelesstools # ifrename iwconfig iwevent iwgetid iwlist iwpriv iwspy
    zellij
  ];
}
