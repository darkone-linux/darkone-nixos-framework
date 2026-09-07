# Stamps the framework release on the host: `/etc/dnf-release` and the boot label.
#
# Answers "which DNF runs this machine?" without a deploy log, on a fleet where
# hosts are updated one at a time and a rollback can leave a node several
# releases behind.
#
# :::note[Unconditional]
# No `enable` option: pure metadata, no service, no cost. `dnfVersion` comes
# from `lib/mk-configuration.nix`, which reads `dnf/VERSION` and the flake
# revision.
# :::
#
# :::tip[Read it]
# ```sh
# cat /etc/dnf-release      # DNF_RELEASE + DNF_REV
# nixos-version             # release appears as a `dnf-X.Y.Z` label tag
# ```
# :::

{ dnfVersion, ... }:

{
  environment.etc."dnf-release".text = ''
    DNF_RELEASE=${dnfVersion.release}
    DNF_REV=${dnfVersion.rev}
  '';

  # A tag, not `system.nixos.label`: it prefixes the generated label, so the
  # NixOS version that label already carries survives.
  system.nixos.tags = [ "dnf-${dnfVersion.release}" ];
}
