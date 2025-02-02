# Useful programs for advanced users (computer scientists)

{ pkgs, ... }:
{
  home.packages = with pkgs; [
    bat
    btop
    ccrypt
    dos2unix
    duf
    gawk
    htop
    jq
    lsof
    psmisc # killall, pstree, pslog, fuser...
    pv
    ranger
    rename
    rsync
    strace
    zellij
  ];
}
