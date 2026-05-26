# Test-only tuning applied to every node in a simulation.
#
# :::caution[Tests only]
# Imported exclusively by `tests/lib/mk*Test.nix`. Never referenced from
# `modules/`. Provisions the throwaway sops key so secrets decrypt for real.
# Stays qemu-vm-agnostic (no `virtualisation.*`) so the L1 eval tier can
# import it into a plain `nixosSystem`; VM sizing lives in the VM helpers.
# :::
#
# Aim: use.

{ lib, ... }:
{

  # Seam: skip workDir-only bits + neutralize headscale/tailscale.
  darkone.test.standalone = true;

  # Each node owns its nixpkgs (node.pkgsReadOnly = false). The framework
  # enables unfree via hardware.nix, but a scenario may disable core; keep
  # unfree allowed test-wide. mkDefault yields to core's own setting.
  nixpkgs.config.allowUnfree = lib.mkDefault true;

  # Real sops: decrypt with the committed throwaway test key only.
  # (No host SSH key exists in the VM, so drop sshKeyPaths.)
  sops.age.sshKeyPaths = lib.mkForce [ ];
  sops.age.keyFile = lib.mkForce "/etc/sops/age/infra.key";
  sops.age.generateKey = lib.mkForce false;
  environment.etc."sops/age/infra.key".source = ../fixtures/keys/test-infra.age;

  # Provide the self-signed cert fixture for scenarios that need TLS.
  darkone.test.tlsCert = ../fixtures/tls/cert.pem;
  darkone.test.tlsKey = ../fixtures/tls/key.pem;
}
