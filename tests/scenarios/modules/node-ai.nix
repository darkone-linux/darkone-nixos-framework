# L2 — darkone.home.ai: AI coding tools and supporting utilities.
# Verifies the master switch installs core packages and optional agents.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-ai";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testModule = {
    home-manager.users.nix = {
      darkone.home.ai.enable = true;
      darkone.home.ai.enableAider = true;
    };
  };

  testScript = ''
    node1.wait_for_unit("multi-user.target")

    # Core packages — master switch
    node1.succeed("su - nix -c 'aichat --version'")
    node1.succeed("su - nix -c 'llm --version'")
    node1.succeed("su - nix -c 'fabric --version'")

    # Code-quality and file-inspection tools
    node1.succeed("su - nix -c 'ast-grep --version'")
    node1.succeed("su - nix -c 'bat --version'")
    node1.succeed("su - nix -c 'fd --version'")
    node1.succeed("su - nix -c 'rg --version'")
    node1.succeed("su - nix -c 'shellcheck --version'")
    node1.succeed("su - nix -c 'shfmt --version'")
    node1.succeed("su - nix -c 'tokei --version'")

    # Git workflow
    node1.succeed("su - nix -c 'delta --version'")
    node1.succeed("su - nix -c 'gh --version'")

    # Dev workflow
    node1.succeed("su - nix -c 'direnv --version'")
    node1.succeed("su - nix -c 'watchexec --version'")

    # RTK — PreToolUse hook bridge
    node1.succeed("su - nix -c 'rtk --version'")

    # Aider — optional agent
    node1.succeed("su - nix -c 'aider --version'")

    # Aider config file
    node1.succeed("su - nix -c 'test -f ~/.aider.conf.yml'")
    node1.succeed("su - nix -c 'grep -q dark-mode ~/.aider.conf.yml'")
  '';
}
