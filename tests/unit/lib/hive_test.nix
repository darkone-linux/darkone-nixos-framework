# Tests for dnf/lib/hive.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }:
let
  mockHostX86 = {
    hostname = "myhost";
    zone = "lan";
  };
  mockHostArm = {
    hostname = "rpi";
    zone = "lan";
    arch = "aarch64-linux";
  };
  mockNetwork = {
    zones.lan = {
      name = "lan";
      domain = "lan.example.com";
    };
  };
  mockHosts = [
    mockHostX86
    mockHostArm
  ];
in
{
  # getHostArch
  testGetHostArchDefault = {
    expr = dnfLib.getHostArch mockHostX86;
    expected = "x86_64-linux";
  };
  testGetHostArchExplicit = {
    expr = dnfLib.getHostArch mockHostArm;
    expected = "aarch64-linux";
  };

  # mkNodeArgs
  testMkNodeArgsBase = {
    expr = dnfLib.mkNodeArgs {
      host = mockHostX86;
      hosts = mockHosts;
      network = mockNetwork;
    };
    expected = {
      host = mockHostX86;
      hosts = mockHosts;
      network = mockNetwork;
      zone = {
        name = "lan";
        domain = "lan.example.com";
      };
    };
  };
  testMkNodeArgsExtra = {
    expr = dnfLib.mkNodeArgs {
      host = mockHostX86;
      hosts = mockHosts;
      network = mockNetwork;
      extraArgs = {
        users = [ ];
        pkgs-stable = "mock-pkgs";
      };
    };
    expected = {
      host = mockHostX86;
      hosts = mockHosts;
      network = mockNetwork;
      zone = {
        name = "lan";
        domain = "lan.example.com";
      };
      users = [ ];
      pkgs-stable = "mock-pkgs";
    };
  };
  # extraArgs overrides base attrs (last-wins merge)
  testMkNodeArgsExtraOverridesNetwork = {
    expr =
      (dnfLib.mkNodeArgs {
        host = mockHostX86;
        hosts = mockHosts;
        network = mockNetwork;
        extraArgs.network = "overridden";
      }).network;
    expected = "overridden";
  };
}
