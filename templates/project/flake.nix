{
  description = "Darkone NixOS Project — a deployment built on the Darkone NixOS Framework.";

  #----------------------------------------------------------------------------
  # FLAKE INPUTS
  #----------------------------------------------------------------------------
  #
  # The framework is consumed from its public GitHub repo, pinned to a release
  # tag. The tag and the committed `flake.lock` are what make a fresh clone
  # reproducible — tracking `main` would build a different tree every day.
  #
  # Upgrade to a newer release:
  #
  #   1. bump the tag below to the release you want
  #   2. nix flake update dnf     # rewrites flake.lock, commit it
  #   3. nix run .#init           # relink dnf/ onto the revision the lock pins
  #
  # Try one without committing to it:
  #
  #   nixos-rebuild switch --flake .#<host> \
  #     --override-input dnf github:darkone-linux/darkone-nixos-framework/<tag>
  #
  # For co-development against a local working tree of the framework, swap
  # this URL for an absolute `git+file://` pointing at the sibling checkout.

  inputs = {
    dnf.url = "github:darkone-linux/darkone-nixos-framework/v0.5.0";
  };

  #----------------------------------------------------------------------------
  # FLAKE OUTPUTS
  #----------------------------------------------------------------------------
  #
  # The whole assembly logic (Colmena hive, nixosConfigurations, devShells,
  # ISO images, the `init` app) lives in the framework. This project only
  # forwards its own `workDir` (= flake root) so the framework can read its
  # `etc/config.yaml`, `var/generated/` and `usr/` overlay.
  #
  # `nix run .#init` re-links `dnf/` onto the revision pinned above — run it
  # after every change of that pin.

  outputs = inputs: inputs.dnf.lib.mkConfigurations ./.;
}
