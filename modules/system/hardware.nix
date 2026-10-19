# Hardware configuration improvements.
#
# Every firmware is loaded (`hardware.enableAllFirmware`), except on a virtual
# machine: `just detect-hw` probes it (`systemd-detect-virt --vm`) and sets
# `darkone.system.hardware.virtual` in `hardware/detected-hardware.nix`. A
# guest also lets Zed run on its emulated GPU (`ZED_ALLOW_EMULATED_GPU`).

{ lib, config, ... }:
let
  cfg = config.darkone.system.hardware;
in
{
  options = {
    darkone.system.hardware.enable = lib.mkEnableOption "Enable hardware optimisations";

    # Intel processors
    darkone.system.hardware.enableIntel = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable intel microcode updates";
    };

    # AMD processors
    darkone.system.hardware.enableAmd = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable amd microcode updates";
    };

    # A guest has no device firmware to load: ~0.8 GiB less to download.
    darkone.system.hardware.virtual = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Virtual machine, no firmware loaded. Set by `just detect-hw`";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.config.allowUnfree = true;
    hardware.enableAllFirmware = !cfg.virtual;

    # `not-detected.nix` turns it back on (`mkDefault`), linux-firmware with it.
    hardware.enableRedistributableFirmware = lib.mkIf cfg.virtual false;
    hardware.cpu.intel = lib.mkIf cfg.enableIntel { updateMicrocode = true; };
    hardware.cpu.amd = lib.mkIf cfg.enableAmd { updateMicrocode = true; };

    # A guest renders with llvmpipe: Zed opens an "unsupported GPU" warning
    # at each start without it.
    environment.sessionVariables.ZED_ALLOW_EMULATED_GPU = lib.mkIf cfg.virtual "1";
  };
}
