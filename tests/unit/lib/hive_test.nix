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

  # MicroVM inventory: `hv` runs `guest`; `bare` carries the feature without
  # value, which the generator fills with the zone name.
  mockHypervisor = {
    hostname = "hv";
    zone = "lan";
    ip = "10.1.1.2";
  };
  mockGuest = {
    hostname = "guest";
    zone = "lan";
    ip = "10.1.1.40";
    features.microvm-guest = "hv";
  };
  mockBareGuest = {
    hostname = "bare";
    zone = "lan";
    ip = "10.1.1.41";
    features.microvm-guest = "lan";
  };
  mockMicrovmHosts = [
    mockHypervisor
    mockGuest
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
  testParseArchAarch64NoBoard = {
    expr = dnfLib.parseArch "aarch64";
    expected = {
      system = "aarch64-linux";
      board = null;
    };
  };

  # Rejected inputs — each used to fail silently or much later.
  # `arch = "rpi5"` (missing `aarch64:`) produced system = "rpi5-linux".
  testParseArchBoardWithoutCpuThrows = {
    expr = (builtins.tryEval (dnfLib.parseArch "rpi5")).success;
    expected = false;
  };
  testParseArchUnknownCpuThrows = {
    expr = (builtins.tryEval (dnfLib.parseArch "riscv64")).success;
    expected = false;
  };
  testParseArchEmptyThrows = {
    expr = (builtins.tryEval (dnfLib.parseArch "")).success;
    expected = false;
  };

  # Unknown board used to yield `board = null`: the Pi was then built as a
  # generic aarch64 machine, with no vendor kernel/firmware/bootloader.
  testParseArchUnknownBoardThrows = {
    expr = (builtins.tryEval (dnfLib.parseArch "aarch64:rpi6")).success;
    expected = false;
  };
  testGetHostBoardUnknownThrows = {
    expr = (builtins.tryEval (dnfLib.getHostBoard { arch = "aarch64:rpi6"; })).success;
    expected = false;
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

  # rpiBoards — one SD image per board known to parseArch
  testRpiBoards = {
    expr = dnfLib.rpiBoards;
    expected = [
      "raspberry-pi-02"
      "raspberry-pi-3"
      "raspberry-pi-4"
      "raspberry-pi-5"
    ];
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

  # getMicrovmHypervisor
  testGetMicrovmHypervisorNone = {
    expr = dnfLib.getMicrovmHypervisor mockMicrovmHosts mockHypervisor;
    expected = null;
  };
  testGetMicrovmHypervisorGuest = {
    expr = dnfLib.getMicrovmHypervisor mockMicrovmHosts mockGuest;
    expected = "hv";
  };

  # Bare feature: its zone-name value matches no host.
  testGetMicrovmHypervisorBareThrows = {
    expr = (builtins.tryEval (dnfLib.getMicrovmHypervisor mockMicrovmHosts mockBareGuest)).success;
    expected = false;
  };
  testGetMicrovmHypervisorSelfThrows = {
    expr =
      (builtins.tryEval (
        dnfLib.getMicrovmHypervisor mockMicrovmHosts (mockHypervisor // { features.microvm-guest = "hv"; })
      )).success;
    expected = false;
  };

  # getMicrovmGuests
  testGetMicrovmGuestsHypervisor = {
    expr = dnfLib.getMicrovmGuests mockMicrovmHosts "hv";
    expected = [ "guest" ];
  };
  testGetMicrovmGuestsNone = {
    expr = dnfLib.getMicrovmGuests mockMicrovmHosts "guest";
    expected = [ ];
  };

  # mkMicrovmLink — tap + MAC from the zone IP
  testMkMicrovmLink = {
    expr = dnfLib.mkMicrovmLink mockGuest;
    expected = {
      tap = "vm-1-40";
      mac = "02:00:0a:01:01:28";
      cid = 299;
    };
  };
  testMkMicrovmLinkMaxOctets = {
    expr = dnfLib.mkMicrovmLink (mockGuest // { ip = "10.255.255.255"; });
    expected = {
      tap = "vm-255-255";
      mac = "02:00:0a:ff:ff:ff";
      cid = 65538;
    };
  };
  testMkMicrovmLinkNoIpThrows = {
    expr = (builtins.tryEval (dnfLib.mkMicrovmLink (removeAttrs mockGuest [ "ip" ]))).success;
    expected = false;
  };

  # spaceGroup / mkSpaceGroups — Kanidm group per `ai-space` host
  testSpaceGroup = {
    expr = dnfLib.spaceGroup "ia-pro";
    expected = "space-ia-pro";
  };
  testMkSpaceGroups = {
    expr = dnfLib.mkSpaceGroups [
      {
        hostname = "ia-pro";
        profile = "ai-space";
        users = [
          "alice"
          "bob"
          "nix"
        ];
      }
      {
        hostname = "ia-solo";
        profile = "ai-space";
        users = [ "nix" ];
      }
      {
        hostname = "srv";
        profile = "server";
        users = [ "alice" ];
      }
      { hostname = "bare"; }
    ];
    expected = {
      space-ia-pro = [
        "alice"
        "bob"
      ];
      space-ia-solo = [ ];
    };
  };
}
