{
  lib ? (import <nixpkgs> { }).lib,
}:

let
  attrs = import ./attrs.nix { inherit lib; };
in
{
  inherit (attrs) hasAttrPath;
}
