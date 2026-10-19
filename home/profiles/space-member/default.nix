# Member of an AI space: light terminal home, no workstation apps.
#
# Replaces the member's own profile on an `ai-space` host. Agent tools (Claude
# Code, Codex, MCP) come with the space, not with this profile. Per user:
# `usr/users/<login>/space.nix` (every space), `spaces/<host>.nix` (one space).

{ pkgs, ... }: {
  imports = [ ./../minimal ];

  programs.git.enable = true;
  home.packages = with pkgs; [
    vim
    tmux
    ripgrep
    jq
  ];
}
