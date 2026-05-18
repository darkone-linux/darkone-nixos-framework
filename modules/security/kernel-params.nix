# Dynamic kernel configuration: boot parameters and sysctls (R8–R14). (wip)
#
# Rules applicable without recompiling the kernel. Covers memory options (R8),
# system sysctls (R9), disabling module loading (R10), Yama/ptrace (R11),
# IPv4 network sysctls (R12), IPv6 disabling (R13),
# and filesystem sysctls (R14).
#
# :::caution[Activation]
# The `enable` option follows `darkone.system.security.enable` by default.
# Rules (Rxx/Cxx) are activated based on level, category, and excludes
# defined in `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R8 — SMT disabled]
# `mds=full,nosmt` and `mitigations=auto,nosmt` disable hyperthreading,
# which reduces multi-threaded throughput by around 30%. Evaluate on compute
# servers before enabling the `intermediary` level.
# :::
#
# :::caution[R9 — unprivileged_userns_clone=0]
# Breaks rootless Docker, rootless Podman, non-suid bubblewrap, and Flatpak.
# Use the R9 exception if these tools are required.
# :::
#
# :::caution[R10 — Modules disabled]
# Any new device requiring a module not pre-loaded needs a reboot.
# Mutually exclusive with `nixos-rebuild switch` on the driver side.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.kernel-params;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.kernel-params.enable = lib.mkEnableOption "Enable ANSSI dynamic kernel parameters (R8–R14).";
  };

  config = lib.mkMerge [
    { darkone.security.kernel-params.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R8 — Memory options on the command line (intermediary, base)
        # sideEffects: init_on_* ~1-3% CPU, nosmt ~-30% multi-thread, debugfs=off breaks perf
        (lib.mkIf (isActive "R8" "intermediary" "base" [ ]) {
          boot.kernelParams = [
            "l1tf=full,force" # L1 Terminal Fault: full mitigation + SMT disabled
            "page_poison=on" # Poisoning of freed pages
            "pti=on" # Page Table Isolation (Meltdown)
            "slab_nomerge=yes" # No slab merging (complicates heap overflow)
            "slub_debug=FZP" # Slab debug: Freelist / Zero / Poison
            "spec_store_bypass_disable=seccomp" # Spectre v4 via seccomp
            "spectre_v2=on" # Spectre v2
            "mds=full,nosmt" # MDS + SMT disabled
            "mce=0" # Panic on uncorrected MCE
            "page_alloc.shuffle=1" # Page allocator randomization
            "rng_core.default_quality=500" # HWRNG quality for CSPRNG
            "init_on_alloc=1" # Memory wipe on allocation
            "init_on_free=1" # Memory wipe on free
            "randomize_kstack_offset=on" # Kernel stack ASLR
            "vsyscall=none" # Disable legacy vsyscall
            "mitigations=auto,nosmt" # All CPU vulnerabilities (belt-and-suspenders)
            "debugfs=off" # Forbid /sys/kernel/debug
          ];
        })

        # R9 — Kernel sysctls (intermediary, base)
        # sideEffects: unprivileged_userns_clone=0 breaks rootless Docker/Podman, Flatpak
        (lib.mkIf (isActive "R9" "intermediary" "base" [ ]) {
          boot.kernel.sysctl = {
            # Memory and processes
            "kernel.kexec_load_disabled" = 1; # Disable kexec (except tag needs-kexec)
            "kernel.unprivileged_userns_clone" = 0; # linux-hardened: no unprivileged userns
            "kernel.core_uses_pid" = 1; # core dump with PID in the name
            "vm.unprivileged_userfaultfd" = 0; # Forbid unprivileged userfaultfd
            "kernel.kptr_restrict" = 2; # Hide kernel pointers (/proc/kallsyms)
            "kernel.io_uring_disabled" = 2; # Forbid io_uring except root
            "dev.tty.ldisc_autoload" = 0; # No automatic ldisc loading
            "dev.tty.legacy_tiocsti" = 0; # Forbid TIOCSTI injection
            "kernel.perf_event_paranoid" = 3; # Restrict perf_events to admins
            "kernel.panic_on_oops" = 1; # Panic on kernel oops
            "kernel.dmesg_restrict" = 1; # Restrict dmesg to admins

            # General networking
            "net.core.bpf_jit_harden" = 2; # Harden the BPF JIT
          };
        })

        # R10 — Disable module loading (reinforced, base, tag: disable-kernel-module-loading)
        # sideEffects: cannot add a device without a reboot
        (lib.mkIf (isActive "R10" "reinforced" "base" [ "disable-kernel-module-loading" ]) {
          boot.kernel.sysctl."kernel.modules_disabled" = 1;

          # PREREQUISITE: list every required module in boot.kernelModules
          # and boot.initrd.kernelModules before enabling this rule.
          # TODO: NixOS assertion checking that boot.kernelModules is non-empty
        })

        # R11 — Enable Yama (intermediary, base)
        # sideEffects: ptrace_scope=2 prevents non-root gdb/strace; =3 same for root
        (lib.mkIf (isActive "R11" "intermediary" "base" [ ]) {

          # Reinforced level: ptrace_scope=2; high level: 3
          boot.kernel.sysctl."kernel.yama.ptrace_scope" =
            if dnfLib.levelMapping.${mainSecurityCfg.level} >= dnfLib.levelMapping."reinforced" then 2 else 1;
          # Full LSM stack is configured in complement.nix (C2)
        })

        # R12 — IPv4 network sysctls (intermediary, base)
        # sideEffects: arp_filter=1 may break multi-interface VRRP/keepalived
        (lib.mkIf (isActive "R12" "intermediary" "base" [ ]) {
          boot.kernel.sysctl = {

            # Antispoofing and filtering
            "net.ipv4.conf.all.rp_filter" = 1;
            "net.ipv4.conf.default.rp_filter" = 1;
            "net.ipv4.conf.all.accept_redirects" = 0;
            "net.ipv4.conf.default.accept_redirects" = 0;
            "net.ipv4.conf.all.secure_redirects" = 0;
            "net.ipv4.conf.default.secure_redirects" = 0;
            "net.ipv4.conf.all.send_redirects" = 0;
            "net.ipv4.conf.default.send_redirects" = 0;
            "net.ipv4.conf.all.accept_source_route" = 0;
            "net.ipv4.conf.default.accept_source_route" = 0;

            # ICMP
            "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
            "net.ipv4.icmp_ignore_bogus_error_responses" = 1;

            # Logging
            "net.ipv4.conf.all.log_martians" = 1;
            "net.ipv4.conf.default.log_martians" = 1;

            # TCP
            "net.ipv4.tcp_syncookies" = 1; # SYN flood protection
            "net.ipv4.tcp_timestamps" = 0; # No timestamps (fingerprintability)
            "net.ipv4.tcp_sack" = 1; # SACK enabled (anti-DoS SACK panic kernel >5.4)
          };
        })

        # R13 — Disable IPv6 (intermediary, base, tag: no-ipv6)
        # sideEffects: breaks IPv6-only services (Cloudflare, AWS Egress-only)
        # Note: inactive by default (tag absent). Prefer IPv6 hardening over disabling.
        (lib.mkIf (isActive "R13" "intermediary" "base" [ "no-ipv6" ]) {
          networking.enableIPv6 = false;
          boot.kernelParams = [ "ipv6.disable=1" ];
          boot.kernel.sysctl = {
            "net.ipv6.conf.all.disable_ipv6" = 1;
            "net.ipv6.conf.default.disable_ipv6" = 1;
          };
        })

        # R14 — Filesystem sysctls (intermediary, base)
        # sideEffects: protected_regular=2 may break daemons creating files in /tmp
        (lib.mkIf (isActive "R14" "intermediary" "base" [ ]) {
          boot.kernel.sysctl = {
            "fs.protected_hardlinks" = 1; # Forbid hardlinks to non-owned files
            "fs.protected_symlinks" = 1; # Forbid symlinks in sticky dirs
            "fs.protected_fifos" = 2; # Protect FIFOs in sticky dirs
            "fs.protected_regular" = 2; # Protect regular files in sticky dirs
            "fs.suid_dumpable" = 0; # No core dump for setuid binaries
          }

          # binfmt_misc disabled unless tag needs-binfmt present (consistent with R23)
          // lib.optionalAttrs (!(lib.elem "needs-binfmt" mainSecurityCfg.excludes)) {
            "fs.binfmt_misc.status" = 0;
          };
        })
      ]
    ))
  ];
}
