# Member of an AI space: light terminal home, no workstation apps.
#
# Replaces the member's own profile on an `ai-space` host. Agent tools (Claude
# Code, Codex, MCP, skills) come from the space (`darkone.home.aiSpace`).
# Per user: `usr/users/<login>/space.nix` (every space), `spaces/<host>.nix`
# (one space).

{ lib, pkgs, ... }: {
  imports = [ ./../minimal ];

  darkone.home.aiSpace.enable = lib.mkDefault true;
  programs.git.enable = true;
  home.packages = with pkgs; [
    vim
    tmux
    ripgrep
    jq
  ];
}
