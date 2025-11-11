# A full zsh installation with aliases, bindkeys and optimized prompt.
#
# :::tip[Some shortcuts]
# - `l`, `la`, `ll`: ls with options
# - `vz`: vim + fzf
# - `nx`: cd /etc/nixos
# - `nf`: nixfmt
# - `nc`: deadnix
# - `dnf`: cd /home/nix/dnf
# - `mrproper`: nix-collect-garbage(s) + switch-to-conf boot
# - `treef`: tree with files (eza)
# - `treed`: tree only dirs (eza)
# :::

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
    darkone.console.zsh.enableForRoot = lib.mkEnableOption "Root home manager ZSH configuration";
  };

  config = lib.mkIf cfg.enable {

    # ZSH additional packages (-vim)
    environment.systemPackages = with pkgs; [
      eza
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
        la = "ls -la";
        ll = "ls -l";
        l = "eza --icons -a --group-directories-first -1 --group --git --long";
        vz = "vim `fzf`";
        nx = "cd /etc/nixos";
        nf = "nixfmt -s"; # Nix Format
        nc = "deadnix"; # Nix Check
        dnf = "cd /home/nix/dnf";
        mrproper = "nix-collect-garbage --delete-old && sudo nix-collect-garbage -d && sudo /run/current-system/bin/switch-to-configuration boot";
        treef = "eza --icons --tree --group-directories-first";
        treed = "eza --icons --tree --group-directories-first --only-dirs";
      };
      promptInit = "source ${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      shellInit = ''
        export MANPAGER="less -M -R -i --use-color -Dd+R -Du+B -DHkC -j5";
        bindkey "^A" beginning-of-line
        bindkey "^E" end-of-line
        bindkey "^D" delete-char
        bindkey "^R" history-incremental-search-backward
        bindkey "^J" down-line-or-history
        bindkey "^K" up-line-or-history
        bindkey "^L" forward-word
      '';
    };

    # Prevent the new user dialog in zsh
    system.userActivationScripts.zshrc = "[ -f .zshrc ] || touch .zshrc";

    # Set zsh as the default shell
    users.defaultUserShell = pkgs.zsh;

    # ZSH minimal configuration for root
    # TODO: faire qqchose de plus propre pour le home de root
    home-manager = lib.mkIf cfg.enableForRoot {
      users.root = {
        home.stateVersion = config.system.nixos.release;
        programs.zsh = {
          enable = true;
          autocd = true;
          plugins = [
            {
              name = "powerlevel10k-config";
              src = ./../../../dotfiles;
              file = "p10k.zsh";
            }
            {
              name = "zsh-powerlevel10k";
              src = "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/";
              file = "powerlevel10k.zsh-theme";
            }
          ];
        };
      };
    };
  };
}
