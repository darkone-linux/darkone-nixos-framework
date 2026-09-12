# Home profile: UMI (Unified Multimodal Input) user, touch + voice + gaze instead of keyboard/mouse.
#
# :::note[Usage]
# Assign with `profile: "umi"` in etc/config.yaml. Designed for hosts using
# the `darkone.host.umi` profile (which provides udev/uinput and the Xorg
# session pinning).
# :::
{

  imports = [ ./../normal ];

  # Multimodal input: Talon autostart (voice, gaze) + Onboard (touch)
  darkone.home.umi.enable = true;
}
