# Overlay: expose `pkgs.openclaw-gateway` and the runtime plugins DNF loads
# (Matrix channel, Codex runtime, Lobster workflows) from the
# openclaw/nix-openclaw flake.
#
# Lazy: the input is only fetched by a host that reads the attribute, i.e. an
# AI space running `darkone.service.openclaw`. Upstream ships no aarch64-linux
# build: reading it there fails, as any absent package would.

{ nix-openclaw }:

system: _final: _prev:
let
  inherit (nix-openclaw.packages.${system})
    openclaw-gateway
    openclaw-runtime-plugin-codex
    openclaw-runtime-plugin-lobster
    openclaw-runtime-plugin-matrix
    ;
in
{
  inherit
    openclaw-gateway
    openclaw-runtime-plugin-codex
    openclaw-runtime-plugin-lobster
    openclaw-runtime-plugin-matrix
    ;
}
