{
  config,
  users,
  network,
  ...
}:
let

  # Extraction of current user from host configuration
  user = users.${config.home.username};
in
{
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "${user.name}";
        email =
          if (builtins.hasAttr "email" user) then
            "${user.email}"
          else
            "${config.home.username}@${network.domain}";
      };
      alias = {
        amend = "!git add . && git commit --amend --no-edit";
        pf = "!git push --force";
      };
      core = {
        editor = "vim";
        whitespace = "fix,-indent-with-non-tab,trailing-space,cr-at-eol";
      };
      delta = {
        enable = true;
        options = {
          "navigate" = true;
        };
      };
      diff.tool = "vimdiff";
      web.browser = "firefox";
      push.default = "tracking";
      push.autoSetupRemote = true;
      pull.rebase = false;
      init.defaultBranch = "main";
      color.ui = true;
    };
    ignores = [
      "*~"
      "*.swp"
      ".vscode"
      ".idea"
    ];

    # Undefined but required from 02/2025
    signing.format = "ssh";
  };
}
