{ lib }:

let
  strings = import ./strings.nix { inherit lib; };
  srv = import ./srv.nix { inherit lib strings; };
in
{
  inherit (strings) ucFirst;
  inherit (srv) extractServiceParams;
}
