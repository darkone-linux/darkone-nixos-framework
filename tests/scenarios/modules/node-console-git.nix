# L2 — darkone.console.git: git present, LFS enabled, system-wide aliases.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-console-git";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testModule = {
    darkone.console.git.enable = true;
  };

  testScript = ''
    node1.wait_for_unit("multi-user.target")
    node1.succeed("git --version")
    node1.succeed("git lfs version")
    node1.succeed("git config --system alias.tree | grep -q 'log --graph'")
  '';
}
