# Default VM size of a simulated DNF node.
#
# qemu-vm options only: kept out of `test-tuning.nix`, which the L1 eval tier
# imports into a plain `nixosSystem`.

{
  virtualisation = {
    memorySize = 2048;
    cores = 2;
    diskSize = 4096;
  };
}
