# A pre-configured git environment.

{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.darkone.console.git;
in
{
  options = {
    darkone.console.git.enable = lib.mkEnableOption "Pre-configured git environment";
  };

  config = lib.mkIf cfg.enable {

    # dependencies
    environment.systemPackages = with pkgs; [ peco ];

    # Customized git
    programs.git = {
      enable = true;
      lfs.enable = true;
      config = {
        push = {
          default = "simple";
          autoSetupRemote = true;
        };
        init = {
          defaultBranch = "main";
        };
        core = {
          trustctime = false;
          quotePath = false;
          editor = "vim";
        };
        alias = {
          hdf = "!git hist | peco | awk '{print $2}' | xargs -I {} git diff {}^ {}";
          hist =
            ''log --pretty=format:"%Cgreen%h %Creset%cd %Cblue[%cn]''
            + ''%Creset%s%C(yellow)%d%C(reset)" --graph --date=relative --decorate --all'';
          tre =
            ''log --graph --name-status --pretty=format:"%C(red)%h %C(reset)(%cd)''
            + ''%C(green)%an %Creset%s %C(yellow)%d%Creset" --date=relative'';
          tree =
            "log --graph --abbrev-commit --decorate "
            + "--format=format:'%C(bold blue)%h%C(reset) -"
            + " %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset)"
            + " %C(dim white)- %an%C(reset)%C(auto)%d%C(reset)'";
          treee =
            "lg2-specific = log --graph --abbrev-commit --decorate "
            + "--format=format:'%C(bold blue)%h%C(reset) - %C(bold cyan)%aD%C(reset)"
            + " %C(bold green)(%ar)%C(reset)%C(auto)%d%C(reset)%n"
            + " %C(white)%s%C(reset) %C(dim white)-"
            + " %an%C(reset)' --all";
        };
        url = {
          "https://github.com/" = {
            insteadOf = [
              "gh:"
              "github:"
            ];
          };
        };
      };
    };
  };
}
