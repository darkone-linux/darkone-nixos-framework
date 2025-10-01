_: {
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
    defaultCommand = "rg --files --hidden";
    defaultOptions = [
      "--no-mouse"
      "--info=inline-right"
    ];
  };

  # z command to replace cd
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  # ls alternative
  programs.eza = {
    enable = true;
    enableZshIntegration = false;
  };

  # cat alternative + man pages
  programs.bat.enable = true;
  home.sessionVariables = {
    MANPAGER = "sh -c 'col -bx | bat -l man -p'";
    MANROFFOPT = "-c";
  };

  # rg command -> recursive grep
  programs.ripgrep.enable = true;

  programs.btop = {
    enable = true;
    settings = {
      proc_per_core = true;
      update_ms = 1000;
    };
  };
}
