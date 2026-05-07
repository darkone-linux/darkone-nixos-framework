# Configuration statique du noyau — recompilation requise (R15–R27). (wip)
#
# Ces règles nécessitent un noyau personnalisé via `boot.kernelPackages`.
# NixOS le permet avec `structuredExtraConfig`. Toutes ces règles portent le
# tag `kernel-recompile` : elles sont ignorées si ce tag figure dans `excludes`.
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::danger[Pas de cache binaire NixOS]
# L'activation de ces règles implique la recompilation locale du noyau
# (~30–60 min par mise à jour selon CPU). Aucun cache binaire public ne
# couvre un noyau custom. Réserver aux parcs avec MCO outillé.
# :::
#
# :::caution[Modules out-of-tree]
# R18 (modules signés) rend obligatoire la signature de tout module externe
# (NVIDIA, ZFS, VirtualBox, v4l2loopback…) via le pipeline Nix.
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

  # Tag commun à toutes les règles de ce groupe
  kernelTag = [ "kernel-recompile" ];

  # Config noyau accumulée par les règles actives
  # Chaque règle contribue à structuredExtraConfig via lib.mkMerge
  kernelConfig = lib.mkMerge [

    # R15 — Options de compilation gestion mémoire (high)
    # sideEffects: REFCOUNT_FULL ~1% CPU, HARDENED_USERCOPY casse vieux drivers binaires
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

    # R16 — Structures de données (high)
    # sideEffects: ~2-5% CPU syscall-intensive, kernel panic sur corruption (ECC obligatoire)
    (lib.optionalAttrs (isActive "R16" "high" "base" kernelTag) {
      DEBUG_CREDENTIALS = lib.kernel.yes;
      DEBUG_NOTIFIERS = lib.kernel.yes;
      DEBUG_LIST = lib.kernel.yes;
      DEBUG_SG = lib.kernel.yes;
      BUG_ON_DATA_CORRUPTION = lib.kernel.yes;
    })

    # R17 — Allocateur mémoire (high)
    # sideEffects: PAGE_POISONING ~3-5% CPU allocations massives
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

    # R18 — Modules signés (high)
    # sideEffects: tout module OOT doit être signé, clé privée à protéger
    (lib.optionalAttrs (isActive "R18" "high" "base" kernelTag) {
      MODULES = lib.kernel.yes;
      MODULE_SIG = lib.kernel.yes;
      MODULE_SIG_FORCE = lib.kernel.yes;
      MODULE_SIG_ALL = lib.kernel.yes;
      MODULE_SIG_SHA512 = lib.kernel.yes;
      # MODULE_SIG_KEY gérée via sops-nix : "/var/lib/anssi-mod-signing.pem"
      # TODO: wirer avec darkone.system.sops pour la clé de signature
    })

    # R19 — Réactions aux évènements anormaux (high)
    # sideEffects: PANIC_TIMEOUT=-1 : machine inopérante après oops sans watchdog
    (lib.optionalAttrs (isActive "R19" "high" "base" kernelTag) {
      BUG = lib.kernel.yes;
      PANIC_ON_OOPS = lib.kernel.yes;
      PANIC_TIMEOUT = lib.kernel.freeform "-1";
    })

    # R20 — Primitives LSM (high)
    # sideEffects: Lockdown interdit /dev/mem, kexec, MSR write, flashrom
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

    # R21 — Plugins GCC (high)
    # sideEffects: RANDSTRUCT impose de recompiler tous les modules avec la même graine
    # Non applicable sur Clang (marqué automatiquement)
    (lib.optionalAttrs (isActive "R21" "high" "base" kernelTag && !pkgs.stdenv.cc.isClang) {
      GCC_PLUGINS = lib.kernel.yes;
      GCC_PLUGIN_LATENT_ENTROPY = lib.kernel.yes;
      GCC_PLUGIN_STACKLEAK = lib.kernel.yes;
      GCC_PLUGIN_STRUCTLEAK = lib.kernel.yes;
      GCC_PLUGIN_STRUCTLEAK_BYREF_ALL = lib.kernel.yes;
      GCC_PLUGIN_RANDSTRUCT = lib.kernel.yes;
    })

    # R22 — Pile réseau (high)
    # sideEffects: voir R13 pour IPv6
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

    # R23 — Comportements divers du noyau (high)
    # sideEffects: KEXEC=n → kdump impossible ; HIBERNATION=n → pas de suspend-to-disk
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

    # R24 — Spécificités x86 32 bits (high, architectures: i686)
    (lib.optionalAttrs
      (isActive "R24" "high" "base" kernelTag && pkgs.stdenv.hostPlatform.linuxArch == "i686")
      {
        HIGHMEM64G = lib.kernel.yes;
        X86_PAE = lib.kernel.yes;
        DEFAULT_MMAP_MIN_ADDR = lib.kernel.freeform "65536";
        RANDOMIZE_BASE = lib.kernel.yes;
      }
    )

    # R25 — Spécificités x86_64 (high, architectures: x86_64)
    # sideEffects: IA32_EMULATION=n casse les binaires 32 bits (Steam, vieux jeux)
    (lib.optionalAttrs (isActive "R25" "high" "base" kernelTag && pkgs.stdenv.hostPlatform.isx86_64) {
      DEFAULT_MMAP_MIN_ADDR = lib.kernel.freeform "65536";
      RANDOMIZE_BASE = lib.kernel.yes;
      RANDOMIZE_MEMORY = lib.kernel.yes;
      PAGE_TABLE_ISOLATION = lib.kernel.yes;
      IA32_EMULATION = lib.kernel.no;
      MODIFY_LDT_SYSCALL = lib.kernel.no;
    })

    # R26 — ARM 32 bits (high, architectures: arm)
    # sideEffects: OABI_COMPAT=n casse les vieux binaires ARM ABI v3
    (lib.optionalAttrs (isActive "R26" "high" "base" kernelTag && pkgs.stdenv.hostPlatform.isAarch32) {
      DEFAULT_MMAP_MIN_ADDR = lib.kernel.freeform "32768";
      VMSPLIT_3G = lib.kernel.yes;
      STRICT_MEMORY_RWX = lib.kernel.yes;
      CPU_SW_DOMAIN_PAN = lib.kernel.yes;
      OABI_COMPAT = lib.kernel.no;
    })

    # R27 — ARM64 (high, architectures: aarch64)
    # sideEffects: PTR_AUTH/BTI requièrent ARMv8.3+/8.5+
    (lib.optionalAttrs (isActive "R27" "high" "base" kernelTag && pkgs.stdenv.hostPlatform.isAarch64) {
      DEFAULT_MMAP_MIN_ADDR = lib.kernel.freeform "32768";
      RANDOMIZE_BASE = lib.kernel.yes;
      ARM64_SW_TTBR0_PAN = lib.kernel.yes;
      UNMAP_KERNEL_AT_EL0 = lib.kernel.yes;
      ARM64_PTR_AUTH = lib.kernel.yes;
      ARM64_BTI = lib.kernel.yes;
    })
  ];

  # Détermine si au moins une règle de recompilation est active
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
    darkone.security.kernel-build.enable = lib.mkEnableOption "Active le module de recompilation noyau ANSSI (R15–R27).";
  };

  config = lib.mkMerge [
    { darkone.security.kernel-build.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf (cfg.enable && needsCustomKernel) {
      boot.kernelPackages =
        if mainSecurityCfg.useHardenedKernel then

          # C1 : linux_hardened avec les patches Grsecurity-lite (Annexe A)
          pkgs.linuxPackages_hardened
        else

          # Noyau custom avec les options R15-R27 seulement
          pkgs.linuxPackagesFor (pkgs.linux.override { structuredExtraConfig = kernelConfig; });

      # Assertion : noyau custom incompatible avec le cache binaire NixOS
      # TODO: ajouter un warning visible à l'évaluation (lib.warn)
    })
  ];
}
