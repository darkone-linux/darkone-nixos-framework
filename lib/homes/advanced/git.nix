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
  # TODO: imagine a way to know the network to considere depending on the host / network
  programs.git = {
    enable = true;
    userName = "${user.name}";
    userEmail =
      if (builtins.hasAttr "email" user) then
        "${user.email}"
      else
        "${config.home.username}@${network.domain}";
    aliases = {
      amend = "!git add . && git commit --amend --no-edit";
      pf = "!git push --force";
    };
    ignores = [
      "*~"
      "*.swp"
      ".vscode"
      ".idea"
    ];
    extraConfig = {
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
      diff.tool = "meld";
      web.browser = "firefox";
      push.default = "tracking";
      push.autoSetupRemote = true;
      pull.rebase = false;
      init.defaultBranch = "main";
      color.ui = true;
    };
  };
}
