# Agrégateur des suites de tests unitaires DNF (dnf/lib/)
# Exposé dans flake.nix sous .#libTests
# Lancer avec : nix-unit --flake .#libTests
{ lib }:
let
  dnfLib = import ../../lib { inherit lib; };
in
{
  lib_strings = import ./lib/strings_test.nix { inherit dnfLib; };
  lib_srv = import ./lib/srv_test.nix { inherit dnfLib; };
  lib_security = import ./lib/security_test.nix { inherit dnfLib; };
  lib_hive = import ./lib/hive_test.nix { inherit dnfLib; };
}
