# Auto-discovers every `*.nix` under tests/scenarios/ (except this file)
# and builds the checks attrset. Check name = relative path with `/`→`-`,
# minus the `.nix` suffix (e.g. services/node-fail2ban.nix ->
# services-node-fail2ban).
#
# A scenario named `*.disabled.nix` produces NO check at all, and the eval
# warns about it. The previous convention — a `runCommand "echo disabled"`
# stub — made `nix flake check` report the scenario as PASSING, hiding the
# coverage gap behind a green tick.
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

  isDisabled = lib.hasSuffix ".disabled.nix";
  disabled = lib.filter isDisabled files;
  active = lib.filter (rel: !(isDisabled rel)) files;

  toCheckName = rel: lib.replaceStrings [ "/" ".nix" ] [ "-" "" ] rel;
in
lib.warnIf (disabled != [ ])
  "DNF scenarios: ${toString (lib.length disabled)} disabled, covered by no check (${lib.concatStringsSep ", " disabled})"
  (
    builtins.listToAttrs (
      map (rel: {
        name = toCheckName rel;
        value = import (root + "/${rel}") { inherit pkgs inputs; };
      }) active
    )
  )
