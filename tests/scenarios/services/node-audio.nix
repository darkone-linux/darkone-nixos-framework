# L2 — darkone.service.audio: pipewire enabled, pulseaudio off.

{ pkgs, inputs }:
(import ../../lib/mkNodeTest.nix { inherit pkgs inputs; }) {
  name = "node-audio";
  workspace = ../../workspaces/node/configs/_smoke;
  host = "node1";

  testModule = {
    darkone.service.audio.enable = true;

    # PipeWire acquires realtime priority through rtkit.
    security.rtkit.enable = true;
  };

  testScript = ''
    node1.wait_for_unit("multi-user.target")

    # PipeWire is a per-user service; a headless VM has no session, so assert
    # the user units are wired rather than a live socket.
    node1.succeed("test -e /etc/systemd/user/pipewire.service")
    node1.succeed("test -e /etc/systemd/user/pipewire.socket")

    # PulseAudio must not be the sound server.
    node1.fail("systemctl is-active pulseaudio")
  '';
}
