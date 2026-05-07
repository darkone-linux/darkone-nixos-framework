# Hardware configuration improvements.

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
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.config.allowUnfree = true;
    hardware.enableAllFirmware = true;
    hardware.cpu.intel = lib.mkIf cfg.enableIntel { updateMicrocode = true; };
    hardware.cpu.amd = lib.mkIf cfg.enableAmd { updateMicrocode = true; };
  };
}
