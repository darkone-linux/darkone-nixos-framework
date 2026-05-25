# Loads a DNF workspace (a real workDir) and exposes its hosts as
# test-driver nodes, WITHOUT modifying mkConfigurations — it consumes the
# public `mkNodes` API (see spec §8/§9).
#
# :::tip
# `nodeOf <host>` returns `{ modules; specialArgs; system; }`, ready to
# replug into `pkgs.testers.runNixOSTest`.
# :::
#
# Aim: use, debug.

{ inputs }:
let
  mkConfigurations = import ../../lib/mk-configuration.nix { inherit inputs; };
in
workDir:
let
  ws = mkConfigurations workDir;
  hosts = import (workDir + "/var/generated/hosts.nix");
  nodes = ws.mkNodes { forTest = true; };
  hostsByName = builtins.listToAttrs (
    map (h: {
      name = h.hostname;
      value = h;
    }) hosts
  );
in
{
  inherit ws nodes hosts;
  hostNames = builtins.attrNames nodes;

  # node = { modules; specialArgs; system; }
  nodeOf = name: nodes.${name};

  # Raw generated host record (zone, ip, services, ...) by hostname.
  hostByName = name: hostsByName.${name};
}
