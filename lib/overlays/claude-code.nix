# Overlay: expose `pkgs.claude-code-nix`, the native Claude Code binary of the
# sadjow/claude-code-nix flake (`darkone.home.ai` installs the same one).
#
# For NixOS modules, which get no flake inputs: the agents of an AI space
# (`services.openclaw-gateway` PATH) and its members' homes. New attribute
# only: `pkgs.claude-code` (nixpkgs) stays untouched. Lazy, like any input.

{ claude-code }:

system: _final: _prev: { claude-code-nix = claude-code.packages.${system}.default; }
