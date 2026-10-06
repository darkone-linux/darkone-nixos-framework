# Features of every profile: zsh with powerlevel10k, and the terminal
# shortcut (Ctrl+Alt+T) on Ghostty, else GNOME Console.

{
  pkgs,
  lib,
  config,
  osConfig,
  ...
}:
let
  graphic = osConfig.darkone.graphic.gnome.enable;
  hasGhostty = config.programs.ghostty.enable;
  termExec = if hasGhostty then "ghostty" else "kgx";
in
{
  # Install gnome console if no ghostty available
  home.packages = lib.optional (!hasGhostty && graphic) pkgs.gnome-console;

  # Terminal key binding
  dconf.settings = lib.mkIf graphic {
    "org/gnome/desktop/default-applications/terminal" = {
      exec = termExec;
      exec-arg = "";
    };
    "org/gnome/settings-daemon/plugins/media-keys" = {
      custom-keybindings = [
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
      ];
    };
    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
      binding = "<Ctrl><Alt>t";
      command = termExec;
      name = "open-terminal";
    };
  };

  # Common ZSH configuration
  programs.zsh = {
    enable = true;
    autocd = true;
    plugins = [

      # p10k.zsh alone: the whole assets/ tree would land in every home and
      # rebuild it at each asset change.
      {
        name = "powerlevel10k-config";
        src = lib.fileset.toSource {
          root = ./../../../assets;
          fileset = ./../../../assets/p10k.zsh;
        };
        file = "p10k.zsh";
      }
      {
        name = "zsh-powerlevel10k";
        src = "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/";
        file = "powerlevel10k.zsh-theme";
      }
    ];
  };
}
