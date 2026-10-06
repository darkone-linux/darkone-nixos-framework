# Home profile: UMI (Unified Multimodal Input) user, touch + voice + gaze instead of keyboard/mouse.
#
# :::note[Usage]
# Assign with `profile: "umi"` in etc/config.yaml. Full setup on hosts using
# the `darkone.host.umi` profile (Cinnamon X11 session, Talon, Tobii); on any
# other host, GNOME Wayland with its native accessibility.
# :::

{ lib, ... }: {
  imports = [ ./../normal ];

  # Multimodal input: Talon autostart (voice, gaze) + Onboard (touch)
  darkone.home.umi.enable = lib.mkDefault true;
}
