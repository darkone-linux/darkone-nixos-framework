# Useful programs for network / sysadmin users

{ pkgs, ... }:
{
  # NOTE: do NOT install busybox (incompatible readlink with nix build)
  home.packages = with pkgs; [
    bridge-utils
    gnupg
    inetutils
    iptraf-ng
    iw
    nettools
    nmap
    ntp
    ntpstat
    pinentry-curses
    tcpdump
    wirelesstools # ifrename iwconfig iwevent iwgetid iwlist iwpriv iwspy
  ];

  #  programs.gpg.enable = true;
  #  services.gpg-agent = {
  #    enable = true;
  #    defaultCacheTtl = 34560000;
  #    maxCacheTtl = 34560000;
  #    enableSshSupport = true;
  #    enableZshIntegration = true;
  #    pinentryPackage = pkgs.pinentry-curses;
  #  };
}
