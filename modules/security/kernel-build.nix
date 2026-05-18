# Static kernel configuration — requires recompilation (R15–R27). (wip)
#
# These rules require a custom kernel via `boot.kernelPackages`.
# NixOS allows this through `structuredExtraConfig`. All these rules carry
# the `kernel-recompile` tag: they are skipped if that tag is in `excludes`.
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::danger[No NixOS binary cache]
# Enabling these rules implies a local kernel recompilation
# (~30–60 min per update depending on CPU). No public binary cache covers
# a custom kernel. Reserve for fleets with proper MCO tooling.
# :::
#
# :::caution[Out-of-tree modules]
# R18 (signed modules) makes signing any external module mandatory
# (NVIDIA, ZFS, VirtualBox, v4l2loopback…) via the Nix pipeline.
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
  cfg = config.darkone.security.kernel-build;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });

  # Common tag for all rules in this group
  kernelTag = [ "kernel-recompile" ];

  # Kernel config accumulated by active rules
  # Each rule contributes to structuredExtraConfig via lib.mkMerge
  kernelConfig = lib.mkMerge [

    # R15 — Memory management compile options (high)
    # sideEffects: REFCOUNT_FULL ~1% CPU, HARDENED_USERCOPY breaks old binary drivers
    (lib.optionalAttrs (isActive "R15" "high" "base" kernelTag) {
      STRICT_KERNEL_RWX = lib.kernel.yes;
      DEBUG_WX = lib.kernel.yes;
      STACKPROTECTOR_STRONG = lib.kernel.yes;
      HARDENED_USERCOPY = lib.kernel.yes;
      VMAP_STACK = lib.kernel.yes;
      FORTIFY_SOURCE = lib.kernel.yes;
      SCHED_STACK_END_CHECK = lib.kernel.yes;
      DEVMEM = lib.kernel.no;
      DEVKMEM = lib.kernel.no;
      PROC_KCORE = lib.kernel.no;
      LEGACY_VSYSCALL_NONE = lib.kernel.yes;
      COMPAT_VDSO = lib.kernel.no;
      SECURITY_DMESG_RESTRICT = lib.kernel.yes;
      RETPOLINE = lib.kernel.yes;
      REFCOUNT_FULL = lib.kernel.yes;
    })

    # R16 — Data structures (high)
    # sideEffects: ~2-5% CPU on syscall-intensive workloads, kernel panic on corruption (ECC required)
    (lib.optionalAttrs (isActive "R16" "high" "base" kernelTag) {
      DEBUG_CREDENTIALS = lib.kernel.yes;
      DEBUG_NOTIFIERS = lib.kernel.yes;
      DEBUG_LIST = lib.kernel.yes;
      DEBUG_SG = lib.kernel.yes;
      BUG_ON_DATA_CORRUPTION = lib.kernel.yes;
    })

    # R17 — Memory allocator (high)
    # sideEffects: PAGE_POISONING ~3-5% CPU on heavy allocations
    (lib.optionalAttrs (isActive "R17" "high" "base" kernelTag) {
      SLAB_FREELIST_RANDOM = lib.kernel.yes;
      SLUB = lib.kernel.yes;
      SLAB_FREELIST_HARDENED = lib.kernel.yes;
      SLAB_MERGE_DEFAULT = lib.kernel.no;
      SLUB_DEBUG = lib.kernel.yes;
      PAGE_POISONING = lib.kernel.yes;
      PAGE_POISONING_NO_SANITY = lib.kernel.yes;
      PAGE_POISONING_ZERO = lib.kernel.yes;
      COMPAT_BRK = lib.kernel.no;
    })

    # R18 — Signed modules (high)
    # sideEffects: every OOT module must be signed, private key must be protected
    (lib.optionalAttrs (isActive "R18" "high" "base" kernelTag) {
      MODULES = lib.kernel.yes;
      MODULE_SIG = lib.kernel.yes;
      MODULE_SIG_FORCE = lib.kernel.yes;
      MODULE_SIG_ALL = lib.kernel.yes;
      MODULE_SIG_SHA512 = lib.kernel.yes;
      # MODULE_SIG_KEY managed via sops-nix: "/var/lib/anssi-mod-signing.pem"
      # TODO: wire with darkone.system.sops for the signing key
    })

    # R19 — Reactions to abnormal events (high)
    # sideEffects: PANIC_TIMEOUT=-1: machine unresponsive after oops without a watchdog
    (lib.optionalAttrs (isActive "R19" "high" "base" kernelTag) {
      BUG = lib.kernel.yes;
      PANIC_ON_OOPS = lib.kernel.yes;
      PANIC_TIMEOUT = lib.kernel.freeform "-1";
    })

    # R20 — LSM primitives (high)
    # sideEffects: Lockdown forbids /dev/mem, kexec, MSR write, flashrom
    (lib.optionalAttrs (isActive "R20" "high" "base" kernelTag) {
      SECCOMP = lib.kernel.yes;
      SECCOMP_FILTER = lib.kernel.yes;
      SECURITY = lib.kernel.yes;
      SECURITY_YAMA = lib.kernel.yes;
      SECURITY_LANDLOCK = lib.kernel.yes;
      SECURITY_LOCKDOWN_LSM = lib.kernel.yes;
      SECURITY_LOCKDOWN_LSM_EARLY = lib.kernel.yes;
      SECURITY_WRITABLE_HOOKS = lib.kernel.no;
    })

    # R21 — GCC plugins (high)
    # sideEffects: RANDSTRUCT requires recompiling all modules with the same seed
    # Not applicable on Clang (automatically marked)
    (lib.optionalAttrs (isActive "R21" "high" "base" kernelTag && !pkgs.stdenv.cc.isClang) {
      GCC_PLUGINS = lib.kernel.yes;
      GCC_PLUGIN_LATENT_ENTROPY = lib.kernel.yes;
      GCC_PLUGIN_STACKLEAK = lib.kernel.yes;
      GCC_PLUGIN_STRUCTLEAK = lib.kernel.yes;
      GCC_PLUGIN_STRUCTLEAK_BYREF_ALL = lib.kernel.yes;
      GCC_PLUGIN_RANDSTRUCT = lib.kernel.yes;
    })

    # R22 — Network stack (high)
    # sideEffects: see R13 for IPv6
    (
      lib.optionalAttrs (isActive "R22" "high" "base" kernelTag) { SYN_COOKIES = lib.kernel.yes; }
      // lib.optionalAttrs (
        isActive "R22" "high" "base" kernelTag && lib.elem "no-ipv6" mainSecurityCfg.excludes
      ) { IPV6 = lib.kernel.no; }
      //
        lib.optionalAttrs
          (isActive "R22" "high" "base" kernelTag && !(lib.elem "no-ipv6" mainSecurityCfg.excludes))
          {
            IPV6_PRIVACY = lib.kernel.yes;
            IPV6_OPTIMISTIC_DAD = lib.kernel.yes;
          }
    )

    # R23 — Miscellaneous kernel behaviors (high)
    # sideEffects: KEXEC=n → kdump impossible; HIBERNATION=n → no suspend-to-disk
    (lib.optionalAttrs (isActive "R23" "high" "base" kernelTag) (
      {
        LEGACY_PTYS = lib.kernel.no;
        X86_MSR = lib.kernel.no;
      }
      // lib.optionalAttrs (!(lib.elem "needs-kexec" mainSecurityCfg.excludes)) { KEXEC = lib.kernel.no; }
      // lib.optionalAttrs (!(lib.elem "needs-hibernation" mainSecurityCfg.excludes)) {
        HIBERNATION = lib.kernel.no;
      }
      // lib.optionalAttrs (!(lib.elem "needs-binfmt" mainSecurityCfg.excludes)) {
        BINFMT_MISC = lib.kernel.no;
      }
    ))

    # R24 — x86 32-bit specifics (high, architectures: i686)
    (lib.optionalAttrs
      (isActive "R24" "high" "base" kernelTag && pkgs.stdenv.hostPlatform.linuxArch == "i686")
      {
        HIGHMEM64G = lib.kernel.yes;
        X86_PAE = lib.kernel.yes;
        DEFAULT_MMAP_MIN_ADDR = lib.kernel.freeform "65536";
        RANDOMIZE_BASE = lib.kernel.yes;
      }
    )

    # R25 — x86_64 specifics (high, architectures: x86_64)
    # sideEffects: IA32_EMULATION=n breaks 32-bit binaries (Steam, old games)
    (lib.optionalAttrs (isActive "R25" "high" "base" kernelTag && pkgs.stdenv.hostPlatform.isx86_64) {
      DEFAULT_MMAP_MIN_ADDR = lib.kernel.freeform "65536";
      RANDOMIZE_BASE = lib.kernel.yes;
      RANDOMIZE_MEMORY = lib.kernel.yes;
      PAGE_TABLE_ISOLATION = lib.kernel.yes;
      IA32_EMULATION = lib.kernel.no;
      MODIFY_LDT_SYSCALL = lib.kernel.no;
    })

    # R26 — ARM 32-bit (high, architectures: arm)
    # sideEffects: OABI_COMPAT=n breaks old ARM ABI v3 binaries
    (lib.optionalAttrs (isActive "R26" "high" "base" kernelTag && pkgs.stdenv.hostPlatform.isAarch32) {
      DEFAULT_MMAP_MIN_ADDR = lib.kernel.freeform "32768";
      VMSPLIT_3G = lib.kernel.yes;
      STRICT_MEMORY_RWX = lib.kernel.yes;
      CPU_SW_DOMAIN_PAN = lib.kernel.yes;
      OABI_COMPAT = lib.kernel.no;
    })

    # R27 — ARM64 (high, architectures: aarch64)
    # sideEffects: PTR_AUTH/BTI require ARMv8.3+/8.5+
    (lib.optionalAttrs (isActive "R27" "high" "base" kernelTag && pkgs.stdenv.hostPlatform.isAarch64) {
      DEFAULT_MMAP_MIN_ADDR = lib.kernel.freeform "32768";
      RANDOMIZE_BASE = lib.kernel.yes;
      ARM64_SW_TTBR0_PAN = lib.kernel.yes;
      UNMAP_KERNEL_AT_EL0 = lib.kernel.yes;
      ARM64_PTR_AUTH = lib.kernel.yes;
      ARM64_BTI = lib.kernel.yes;
    })
  ];

  # Determines whether at least one recompilation rule is active
  needsCustomKernel =
    isActive "R15" "high" "base" kernelTag
    || isActive "R16" "high" "base" kernelTag
    || isActive "R17" "high" "base" kernelTag
    || isActive "R18" "high" "base" kernelTag
    || isActive "R19" "high" "base" kernelTag
    || isActive "R20" "high" "base" kernelTag
    || isActive "R21" "high" "base" kernelTag
    || isActive "R22" "high" "base" kernelTag
    || isActive "R23" "high" "base" kernelTag
    || mainSecurityCfg.useHardenedKernel;
in
{
  options = {
    darkone.security.kernel-build.enable = lib.mkEnableOption "Enable the ANSSI kernel recompilation module (R15–R27).";
  };

  config = lib.mkMerge [
    { darkone.security.kernel-build.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf (cfg.enable && needsCustomKernel) {
      boot.kernelPackages =
        if mainSecurityCfg.useHardenedKernel then

          # C1: linux_hardened with Grsecurity-lite patches (Annex A)
          pkgs.linuxPackages_hardened
        else

          # Custom kernel with R15-R27 options only
          pkgs.linuxPackagesFor (pkgs.linux.override { structuredExtraConfig = kernelConfig; });

      # Assertion: custom kernel incompatible with the NixOS binary cache
      # TODO: add a warning visible at evaluation time (lib.warn)
    })
  ];
}
