# Test user `darkone`: passwordless keyring forced on, a VM has no LUKS volume.
{
  darkone.home.gnome = {
    enable = true;
    passwordlessKeyring = true;
  };
}
