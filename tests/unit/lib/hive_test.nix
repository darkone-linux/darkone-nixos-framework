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
    arch = "aarch64:rpi5";
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

  # Minimal stand-in for the nixos-raspberrypi flake (only the attrs read by
  # rpiBoardModules), with sentinel values to assert selection/order.
  mockRpi = {
    lib.inject-overlays = "inject-overlays";
    nixosModules = {
      trusted-nix-caches = "trusted-nix-caches";
      raspberry-pi-5.base = "rpi5-base";
    };
  };
in
{
  # parseArch — compact `cpu[:board]` field
  testParseArchDefault = {
    expr = dnfLib.parseArch null;
    expected = {
      system = "x86_64-linux";
      board = null;
    };
  };
  testParseArchX86 = {
    expr = dnfLib.parseArch "x86_64";
    expected = {
      system = "x86_64-linux";
      board = null;
    };
  };
  testParseArchX86LegacyFull = {
    expr = dnfLib.parseArch "x86_64-linux";
    expected = {
      system = "x86_64-linux";
      board = null;
    };
  };
  testParseArchRpi02 = {
    expr = dnfLib.parseArch "aarch64:rpi02";
    expected = {
      system = "aarch64-linux";
      board = "raspberry-pi-02";
    };
  };
  testParseArchRpi3 = {
    expr = dnfLib.parseArch "aarch64:rpi3";
    expected = {
      system = "aarch64-linux";
      board = "raspberry-pi-3";
    };
  };
  testParseArchRpi4 = {
    expr = dnfLib.parseArch "aarch64:rpi4";
    expected = {
      system = "aarch64-linux";
      board = "raspberry-pi-4";
    };
  };
  testParseArchRpi5 = {
    expr = dnfLib.parseArch "aarch64:rpi5";
    expected = {
      system = "aarch64-linux";
      board = "raspberry-pi-5";
    };
  };

  # getHostArch
  testGetHostArchDefault = {
    expr = dnfLib.getHostArch mockHostX86;
    expected = "x86_64-linux";
  };
  testGetHostArchExplicit = {
    expr = dnfLib.getHostArch mockHostArm;
    expected = "aarch64-linux";
  };

  # getHostBoard
  testGetHostBoardDefault = {
    expr = dnfLib.getHostBoard mockHostX86;
    expected = null;
  };
  testGetHostBoardExplicit = {
    expr = dnfLib.getHostBoard mockHostArm;
    expected = "raspberry-pi-5";
  };

  # rpiBoardModules — selection + order (overlays, cache, board base)
  testRpiBoardModules = {
    expr = dnfLib.rpiBoardModules mockRpi "raspberry-pi-5";
    expected = [
      "inject-overlays"
      "trusted-nix-caches"
      "rpi5-base"
    ];
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
