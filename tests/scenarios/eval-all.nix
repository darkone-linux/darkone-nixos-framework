# L1 — evaluate the toplevel of every host across all committed workspaces.
# Append new workspace paths here as variants land.

{ pkgs, inputs }:
(import ../lib/mkEvalTest.nix { inherit pkgs inputs; }) {
  name = "eval-all";
  workspaces = [
    ../workspaces/node/configs/_smoke
    ../workspaces/node/configs/server-forgejo
    ../workspaces/node/configs/server-geneweb
    ../workspaces/node/configs/server-immich
    ../workspaces/node/configs/server-ncps
    ../workspaces/node/configs/server-nix-cache
    ../workspaces/node/configs/disko-server
    ../workspaces/network/configs/dns
    ../workspaces/vpn/configs/multizone
  ];
}
