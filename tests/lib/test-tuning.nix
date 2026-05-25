# Test-only tuning applied to every node in a simulation.
#
# :::caution[Tests only]
# Imported exclusively by `tests/lib/mk*Test.nix`. Never referenced from
# `modules/`. Provisions the throwaway sops key so secrets decrypt for real.
# :::
#
# Aim: use.

{ lib, ... }:
{

  # Seam: skip workDir-only bits + neutralize headscale/tailscale.
  darkone.test.standalone = true;

  # Real sops: decrypt with the committed throwaway test key only.
  # (No host SSH key exists in the VM, so drop sshKeyPaths.)
  sops.age.sshKeyPaths = lib.mkForce [ ];
  sops.age.keyFile = lib.mkForce "/etc/sops/age/infra.key";
  sops.age.generateKey = lib.mkForce false;
  environment.etc."sops/age/infra.key".source = ../fixtures/keys/test-infra.age;

  # Provide the self-signed cert fixture for scenarios that need TLS.
  darkone.test.tlsCert = ../fixtures/tls/cert.pem;
  darkone.test.tlsKey = ../fixtures/tls/key.pem;

  virtualisation = {
    memorySize = 2048;
    cores = 2;
    diskSize = 4096;
  };
}
