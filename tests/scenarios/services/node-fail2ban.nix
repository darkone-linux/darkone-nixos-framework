# L2 — darkone.service.fail2ban: service active, DNF maxretry=1 enforced.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-fail2ban";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testModule = {
    darkone.service.fail2ban.enable = true;
  };

  testScript = ''
    node1.wait_for_unit("multi-user.target")
    node1.wait_for_unit("fail2ban.service")
    node1.succeed("systemctl is-active fail2ban")
    node1.succeed("fail2ban-client get sshd maxretry | grep -q '^1$'")
  '';
}
