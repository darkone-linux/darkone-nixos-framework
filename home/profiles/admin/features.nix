# Useful programs for network / sysadmin users

{ lib, ... }: {
  darkone.home.advanced.enableAdmin = lib.mkDefault true;

  # No image or music creation on an admin account: above the `mkDefault` of
  # `normal`, below a plain value of `usr/users/<login>/`.
  darkone.home.imagery.enable = lib.mkOverride 900 false;
  darkone.home.music.enable = lib.mkOverride 900 false;
}
