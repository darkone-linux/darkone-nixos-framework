# UMI (Unified Multimodal Input) user profile: input-injection group memberships (Talon).
#
# :::note[Companion of home/profiles/umi]
# Imported by `modules/user/build.nix` for every user assigned the `umi`
# profile; the returned definition joins `users.users.<login>` (`mkMerge`).
# :::

{ lib, config, ... }@args:
lib.mkMerge [
  (import ./normal.nix args)
  {

    # Talon needs /dev/uinput (group set by hardware.uinput.enable) and read
    # access to input devices for tracker/keyboard state. UMI hosts only: `input`
    # reads every keyboard of the machine, useless where Talon is absent.
    extraGroups = lib.optionals config.darkone.host.umi.enable [
      "input"
      "uinput"
    ];
  }
]
