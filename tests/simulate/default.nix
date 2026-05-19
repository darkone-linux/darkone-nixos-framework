# DNF L2 simulation tests — NixOS Test Driver scenarios.
#
# Called from flake.nix#checks to expose each scenario as a buildable
# derivation. Running `nix build .#checks.<system>.<name>` builds and
# executes the test VM; success means the test passed.
#
# mkTest injects node.specialArgs (mock DNF specialArgs) and defaults.imports
# (non-DNF modules required by dnfModules — currently sops-nix) so
# individual scenario files only need to declare name, nodes, and testScript.
#
# Adding a new scenario:
# 1. Create `modules/<category>-<name>.nix` returning { name, nodes, testScript }.
# 2. Register it in the attrset below with mkTest.
# 3. Run `just simulate <category>-<name>` to validate.

{
  pkgs,
  dnfLib,
  dnfModules,
  extraModules,
}:
let
  fixtures = import ./fixtures { inherit pkgs dnfLib; };

  mkTest =
    path:
    let
      spec = import path { inherit dnfModules; };
    in
    pkgs.testers.runNixOSTest (
      spec
      // {
        # Inject DNF specialArgs into every node's nixpkgs.lib.nixosSystem call.
        # Using node.specialArgs (not _module.args) to avoid infinite recursion
        # in the NixOS module system.
        node.specialArgs = fixtures.mockSpecialArgs;

        # Import modules required by dnfModules but not part of the framework
        # itself (e.g. sops-nix declares the `sops` option used by system/sops.nix).
        defaults.imports = extraModules;
      }
    );
in
{
  console-git = mkTest ./modules/console-git.nix;
  service-fail2ban = mkTest ./modules/service-fail2ban.nix;
  service-audio = mkTest ./modules/service-audio.nix;
}
