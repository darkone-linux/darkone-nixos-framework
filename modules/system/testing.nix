# Standalone test mode for the NixOS Test Driver (L2 simulations).
#
# When enabled, disables workDir-dependent configuration (sops secrets,
# authorized keys) so individual modules can be exercised in isolation
# without a real consumer workspace or secret store.
#
# :::caution[Tests only]
# Only set `darkone.test.standalone = true` inside `dnf/tests/simulate/`.
# Never enable this in a production NixOS configuration.
# :::

{ lib, ... }:
{
  options.darkone.test.standalone = lib.mkEnableOption
    "Standalone test mode — disables workDir-dependent config (sops, nix.pub keys)";
}
