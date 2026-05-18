# Hardware configuration and secure boot (R1–R7). (wip)
#
# Covers UEFI Secure Boot (R3), lanzaboote, bootloader password (R5),
# signed UKIs (R6), and IOMMU (R7). R1 and R2 (hardware/firmware) are
# out of NixOS scope and only produce a note in the report.
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R3/R4 — Secure Boot]
# The lanzaboote integration requires an initial physical key enrollment
# (`sbctl enroll-keys`). R4 (replacing Microsoft keys) carries a bricking
# risk if the machine does not allow restoration.
# :::
#
# :::caution[R7 — IOMMU]
# May cause crashes with some GPUs/Thunderbolt; I/O overhead ~5–15%
# on very high-throughput NVMe arrays.
# :::

{
  lib,
  dnfLib,
  config,
  pkgs,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.preboot;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });

  # CPU architecture detection for IOMMU parameters (R7)
  cpuVendor =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      "arm"
    else if pkgs.stdenv.hostPlatform.isx86_64 then

      # Intel vs AMD: detected at build, refined at runtime in the checkScript
      "x86"
    else
      "unknown";
in
{
  options = {
    darkone.security.preboot.enable = lib.mkEnableOption "Enable ANSSI secure boot — Secure Boot, IOMMU (R1–R7).";
  };

  config = lib.mkMerge [
    { darkone.security.preboot.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R1 — Choose and configure hardware (high, base)
        # No NixOS implementation possible. Manual checkscript only.
        # sideEffects: none

        # R2 — Configure BIOS/UEFI (intermediary, base)
        # No NixOS implementation possible; future dmidecode hook to expose.
        # sideEffects: none

        # R3 — Enable UEFI Secure Boot (intermediary, base)
        # sideEffects: third-party modules (NVIDIA, OOT ZFS) must be signed
        (lib.mkIf (isActive "R3" "intermediary" "base" [ ]) {

          # Option A: lanzaboote (ANSSI-recommended)
          # boot.lanzaboote = {
          #   enable = true;
          #   pkiBundle = "/var/lib/sbctl";
          # };
          # boot.loader.systemd-boot.enable = lib.mkForce false;

          # Option B: plain systemd-boot (no UKI signature)
          boot.loader.systemd-boot.enable = lib.mkDefault true;
          boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

          # ARCHITECTURAL DECISION: lanzaboote vs plain systemd-boot.
          # Lanzaboote is recommended for full R3 but requires physical key
          # enrollment. To configure via darkone.system.security.secureBootImpl
          # (option to add if needed). For now, systemd-boot by default.
        })

        # R4 — Replace pre-loaded keys (high, base)
        # sideEffects: bricking risk, requires a pre-existing PKI
        # Implementation: sbctl enrollment hook — outside the automated scope.
        # The operator must run manually: sbctl create-keys && sbctl enroll-keys
        # The checkScript will verify the keys' state.

        # R5 — Bootloader password (intermediary, base)
        # sideEffects: losing the password = rescue media mandatory
        (lib.mkIf (isActive "R5" "intermediary" "base" [ ]) {

          # Implemented via Secure Boot (R3+R4): signed cmdline = menu cannot be modified.
          # For GRUB: boot.loader.grub.users."admin".hashedPasswordFile = ...;
          # Standard NixOS uses systemd-boot without a native password → R3 mandatory.
          # TODO: add option darkone.system.security.bootloaderImpl = "secureboot" | "grub"
        })

        # R6 — Protect kernel cmdline and initramfs (high, base)
        # sideEffects: modifying the cmdline requires re-signing, third-party modules via Nix pipeline
        (lib.mkIf (isActive "R6" "high" "base" [ ]) {

          # Signed UKI (Unified Kernel Image) with lanzaboote — see R3
          # boot.initrd.systemd.enable = true;
          # boot.uki.enable = true;
          # TODO: gate on boot.lanzaboote.enable or boot.uki.enable
        })

        # R7 — Enable IOMMU (reinforced, base)
        # sideEffects: possible GPU/Thunderbolt crashes, ~5-15% NVMe I/O overhead
        (lib.mkIf (isActive "R7" "reinforced" "base" [ ]) {
          boot.kernelParams =
            if cpuVendor == "arm" then
              [ "iommu.passthrough=0" ]
            else
              [
                # Intel and AMD: common parameter + runtime-specific one
                # intel_iommu=on / amd_iommu=on is detected by the kernel
                # on modern systems; we force iommu=force for both.
                "iommu=force"
                "iommu.passthrough=0"
                "iommu.strict=1"
              ];

          # TODO: add intel_iommu=on / amd_iommu=on per hostPlatform.cpuType
          # when the info is available at build, otherwise document the runtime check.
        })
      ]
    ))
  ];
}
