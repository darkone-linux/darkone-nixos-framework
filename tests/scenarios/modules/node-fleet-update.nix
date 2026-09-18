# L2 — darkone.admin.fleet-update: tool runs, unattended unit and timer wired.

{ pkgs, inputs }:
let
  # Same `pkgs/` set the overlay hands the node: the version its wrapper owes.
  inherit ((import ../../../pkgs { inherit pkgs; }).fleet-update) version;
in
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-fleet-update";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testModule = {
    darkone.admin.nix.enable = true;
    darkone.admin.fleet-update = {
      enable = true;
      user = "darkone";
      timer.enable = true;
    };
  };

  # The unit is never started: a run needs a fleet and the `nix` deploy
  # identity. `--version` proves the wrapper starts bun on the packaged
  # sources — the one command with no side effect (contract § Version).
  testScript = ''
    node1.wait_for_unit("multi-user.target")
    node1.succeed("fleet-update --version | grep -qxF ${version}")
    node1.succeed("systemctl list-timers --all | grep -q fleet-update.timer")
    node1.succeed("systemctl show -p SuccessExitStatus --value fleet-update.service | grep -qw 4")
    node1.succeed("systemctl show -p KillMode --value fleet-update.service | grep -qx mixed")
  '';
}
