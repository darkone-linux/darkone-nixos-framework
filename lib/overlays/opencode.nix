# Temporary overlay: pins `pkgs.opencode`/`pkgs.opencode-desktop` to 1.18.29
# from `nixpkgs-opencode` (nixpkgs right before #561612).
#
# :::caution[Why]
# 1.18.30 crashes on every prompt (`SystemPrompt.environment` TypeError,
# upstream regression). 1.18.29 is the last version known to work.
# :::
#
# :::tip[Cleanup]
# Drop it once a fix is released upstream: take `pkgs.opencode` from the main
# `nixpkgs` tree again and remove the `nixpkgs-opencode` input (cf. `flake.nix`).
# :::

{ nixpkgs-opencode }:

system: _final: _prev:
let
  pkgs-opencode = import nixpkgs-opencode {
    inherit system;
    config.allowUnfree = true;
  };
in
{
  inherit (pkgs-opencode) opencode opencode-desktop;
}
