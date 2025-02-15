{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.console.zsh;
in
{
  options = {
    darkone.console.zsh.enable = lib.mkEnableOption "ZSH environment";
  };

  config = lib.mkIf cfg.enable {

    # ZSH additional packages
    environment.systemPackages = with pkgs; [
      zsh
      zsh-powerlevel10k
      zsh-forgit
      zsh-fzf-tab
    ];

    # ZSH
    programs.zsh = {
      enable = true;
      enableCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;
      shellAliases = {
        ll = "ls -l";
        vz = "vim `fzf`";
        nx = "cd /etc/nixos";
        nf = "nixfmt -s"; # Nix Format
        nc = "deadnix"; # Nix Check
        dnf = "cd /home/nix/dnf";
        update = "sudo nixos-rebuild switch";
      };
      promptInit = "source ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      shellInit = ''
        export MANPAGER="less -M -R -i --use-color -Dd+R -Du+B -DHkC -j5";
        bindkey "^A" beginning-of-line
        bindkey "^E" end-of-line
        bindkey "^R" history-incremental-search-backward
      '';
    };

    # Prevent the new user dialog in zsh
    system.userActivationScripts.zshrc = "touch .zshrc";

    # Set zsh as the default shell
    users.defaultUserShell = pkgs.zsh;
  };
}
