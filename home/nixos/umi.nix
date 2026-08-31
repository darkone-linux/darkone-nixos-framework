# Gaze user profile: input-injection group memberships (Talon).
#
# :::note[Companion of home/profiles/umi]
# Imported by `modules/user/build.nix` for every user assigned the `umi`
# profile; the returned attrset is merged into `users.users.<login>`.
# :::
{ pkgs, ... }:
{

  # Talon needs /dev/uinput (group set by hardware.uinput.enable) and read
  # access to input devices for tracker/keyboard state
  extraGroups = [
    "input"
    "uinput"
  ];
}
// import ./normal.nix { inherit pkgs; }
