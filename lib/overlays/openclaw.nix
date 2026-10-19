# Overlay: expose `pkgs.openclaw-gateway` from the openclaw/nix-openclaw flake.
#
# Lazy: the input is only fetched by a host that reads the attribute, i.e. an
# AI space running `darkone.service.openclaw`. Upstream ships no aarch64-linux
# build: reading it there fails, as any absent package would.

{ nix-openclaw }:

system: _final: _prev: { openclaw-gateway = nix-openclaw.packages.${system}.openclaw-gateway; }
