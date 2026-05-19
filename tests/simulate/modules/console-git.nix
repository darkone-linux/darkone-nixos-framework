# L2 simulation — darkone.console.git module.
#
# Verifies that the pre-configured git environment is correctly wired:
# git binary present, LFS enabled, custom aliases registered system-wide.

{ dnfModules }:
{
  name = "console-git";

  nodes.machine =
    { ... }:
    {
      imports = [ dnfModules ];

      # Module under test
      darkone.console.git.enable = true;

      # Disable core to avoid workDir dependency on usr/secrets/nix.pub
      # and the host-profile mixin activation (not needed for this test).
      darkone.system.core.enable = false;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # git binary is present
    machine.succeed("git --version")

    # LFS is enabled
    machine.succeed("git lfs version")

    # Custom alias "tree" is registered in the system-wide git config
    machine.succeed("git config --system alias.tree | grep -q 'log --graph'")
  '';
}
