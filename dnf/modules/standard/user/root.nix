# Root user specific settings.
#
# :::danger[Required module]
# This module is enabled by default (required by DNF configuration).
# :::

{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.darkone.user.root;
in
{
  options = {
    darkone.user.root.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Root user specific configuration";
    };
  };

  config = lib.mkIf cfg.enable {

    users.users.root = {

      # default, but explicit here
      shell = pkgs.bashInteractive;

      packages = with pkgs; [
        bridge-utils
        dig
        file
        gawk
        htop
        inetutils
        iw
        less
        lsof
        nettools
        nmap
        pciutils
        psmisc
        rename
        rsync
        strace
        tree
        unzip
        vim
        wget
        zip
      ];
    };

    # Contenu du .bashrc de root, version simple
    environment.etc."root-bashrc".text = ''
      PS1="\[\e[1;41m\] ROOT \[\e[0m\] \[\e[1;34m\]\w\[\e[0m\] # "

      alias ls='ls --color=auto'
      alias grep='grep --color=auto'
      alias diff='diff --color=auto'
      alias ll='ls -alh'
      alias la='ls -A'
      alias l='ls -CF'

      HISTCONTROL=ignoredups:erasedups
      HISTSIZE=5000
      HISTFILESIZE=10000

      # Do not replace files, rm + create
      set -o noclobber

      if [ -x /usr/bin/dircolors ]; then
        eval "$(dircolors -b)"
      fi
    '';

    # On installe ce .bashrc dans /root à chaque rebuild
    system.activationScripts.setupRootBash = {
      text = ''
        install -m 600 /etc/root-bashrc /root/.bashrc
      '';
    };
  };
}
