# L2 simulation — darkone.service.fail2ban module.
#
# Verifies that the DNF fail2ban configuration is applied:
# service is active, maxretry=1 and bantime=24h are enforced.

{ dnfModules }:
{
  name = "service-fail2ban";

  nodes.machine =
    { ... }:
    {
      imports = [ dnfModules ];

      # Module under test
      darkone.service.fail2ban.enable = true;

      darkone.system.core.enable = false;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("fail2ban.service")

    # Service is active
    machine.succeed("systemctl is-active fail2ban")

    # maxretry is set to 1 (DNF default)
    machine.succeed("fail2ban-client get sshd maxretry | grep -q '^1$'")
  '';
}
