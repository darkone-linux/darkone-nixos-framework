# Home profile: 100% gaze-driven user (Tobii + Talon + Onboard), no keyboard.
#
# :::note[Usage]
# Assign with `profile: "umi"` in etc/config.yaml. Designed for hosts using
# the `darkone.host.umi` profile (which provides udev/uinput and the Xorg
# session pinning).
# :::
{

  imports = [ ./../normal ];

  # Gaze input: Talon autostart + Onboard eye-tracking profile
  darkone.home.umi.enable = true;
}
