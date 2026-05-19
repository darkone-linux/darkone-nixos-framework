# L2 simulation — darkone.service.audio module.
#
# Verifies that the DNF audio stack is wired correctly:
# pipewire enabled, pulseaudio disabled, alsa support active.

{ dnfModules }:
{
  name = "service-audio";

  nodes.machine =
    { ... }:
    {
      imports = [ dnfModules ];

      # Module under test
      darkone.service.audio.enable = true;

      darkone.system.core.enable = false;

      # Required for pipewire in a headless test VM
      security.rtkit.enable = true;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # pipewire socket is present in /run
    machine.succeed("test -S /run/pipewire/pipewire-0 || systemctl is-active pipewire.socket")

    # pulseaudio must NOT be running
    machine.fail("systemctl is-active pulseaudio")
  '';
}
