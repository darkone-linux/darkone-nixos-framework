# Overlay: expose `pkgs.openclaw-gateway` and the runtime plugins DNF loads
# (Matrix channel, Codex runtime, Lobster workflows) from the
# openclaw/nix-openclaw flake.
#
# Lazy: the input is only fetched by a host that reads the attribute, i.e. an
# AI space running `darkone.service.openclaw`. Upstream ships no aarch64-linux
# build: reading it there fails, as any absent package would.
#
# :::caution[Temporary: patchelf >= 0.18 breaks the Node binary]
# While nixpkgs' `nodejs_24` is older than OpenClaw's floor, nix-openclaw
# repackages the upstream Node binary with `autoPatchelfHook`. patchelf >= 0.18
# sorts its program headers into an overlapping layout: `ld.so` segfaults.
# `--no-sort` avoids it; drop once nix-openclaw or patchelf ships the fix.
# :::

{ nix-openclaw }:

system: _final: prev:
let
  upstream = nix-openclaw.packages.${system};

  # Binary fallback in use: nixpkgs' Node is older than the one OpenClaw pins.
  binaryNode = prev.lib.versionOlder prev.nodejs_24.version upstream.nodejs_24.version;
  nodejs_24 = upstream.nodejs_24.overrideAttrs { patchelfFlags = [ "--no-sort" ]; };

  # Private package set: the fleet keeps nixpkgs' `nodejs_24`.
  openclawPkgs = prev.appendOverlays (
    prev.lib.optional binaryNode (_: _: { inherit nodejs_24; }) ++ [ nix-openclaw.overlays.default ]
  );
  plugins = openclawPkgs.openclawPackages.openclawRuntimePlugins;
in
{
  inherit (openclawPkgs) openclaw-gateway;
  openclaw-runtime-plugin-codex = plugins.codex;
  openclaw-runtime-plugin-lobster = plugins.lobster;
  openclaw-runtime-plugin-matrix = plugins.matrix;
}
