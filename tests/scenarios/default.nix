# Auto-discovers every `*.nix` under tests/scenarios/ (except this file)
# and builds the checks attrset. Check name = relative path with `/`→`-`,
# minus the `.nix` suffix (e.g. services/node-fail2ban.nix ->
# services-node-fail2ban).
#
# TODO: réorganiser les scénarios (home manager, profiles, combinaisons...)

{ pkgs, inputs }:
let
  inherit (pkgs) lib;

  root = ./.;

  collect =
    prefix: dir:
    lib.concatLists (
      lib.mapAttrsToList (
        n: t:
        let
          rel = if prefix == "" then n else "${prefix}/${n}";
        in
        if t == "directory" then
          collect rel (dir + "/${n}")
        else if lib.hasSuffix ".nix" n && rel != "default.nix" then
          [ rel ]
        else
          [ ]
      ) (builtins.readDir dir)
    );

  files = collect "" root;

  toCheckName = rel: lib.replaceStrings [ "/" ".nix" ] [ "-" "" ] rel;
in
builtins.listToAttrs (
  map (rel: {
    name = toCheckName rel;
    value = import (root + "/${rel}") { inherit pkgs inputs; };
  }) files
)
