# Aggregator for DNF unit test suites (dnf/lib/)
# Exposed in flake.nix as .#libTests
# Run with: nix-unit --flake .#libTests
{ lib }:
let
  dnfLib = import ../../lib { inherit lib; };
in
{
  lib_constants = import ./lib/constants_test.nix { inherit dnfLib; };
  lib_strings = import ./lib/strings_test.nix { inherit dnfLib; };
  lib_date_time = import ./lib/date-time_test.nix { inherit dnfLib; };
  lib_topology = import ./lib/topology_test.nix { inherit dnfLib; };
  lib_service_params = import ./lib/service-params_test.nix { inherit dnfLib; };
  lib_firewall = import ./lib/firewall_test.nix { inherit dnfLib; };
  lib_oidc = import ./lib/oidc_test.nix { inherit dnfLib; };
  lib_homepage = import ./lib/homepage_test.nix { inherit dnfLib; };
  lib_security = import ./lib/security_test.nix { inherit dnfLib; };
  lib_hive = import ./lib/hive_test.nix { inherit dnfLib; };
  lib_paths = import ./lib/paths_test.nix { inherit dnfLib; };
  lib_service_activation = import ./lib/service-activation_test.nix { inherit dnfLib; };
  lib_config_schema = import ./lib/config-schema_test.nix { inherit dnfLib; };
  config_network = import ./config/network_test.nix { inherit dnfLib lib; };
  config_modules = import ./config/modules_test.nix { inherit dnfLib lib; };
}
