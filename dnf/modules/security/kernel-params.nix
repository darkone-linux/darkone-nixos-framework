# Configuration dynamique du noyau : paramètres de démarrage et sysctls (R8–R14). (wip)
#
# Règles applicables sans recompiler le noyau. Couvre les options mémoire (R8),
# les sysctls système (R9), la désactivation du chargement de modules (R10),
# Yama/ptrace (R11), les sysctls réseau IPv4 (R12), la désactivation IPv6 (R13)
# et les sysctls systèmes de fichiers (R14).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R8 — SMT désactivé]
# `mds=full,nosmt` et `mitigations=auto,nosmt` désactivent l'hyperthreading,
# ce qui réduit le débit multi-thread d'environ 30 %. À évaluer sur les serveurs
# de calcul avant d'activer le niveau `intermediary`.
# :::
#
# :::caution[R9 — unprivileged_userns_clone=0]
# Casse Docker rootless, Podman rootless, bubblewrap non-suid et Flatpak.
# Utiliser l'exception R9 si ces outils sont requis.
# :::
#
# :::caution[R10 — Modules désactivés]
# Tout nouveau périphérique requérant un module non pré-chargé nécessite un reboot.
# Mutuellement exclusif avec `nixos-rebuild switch` côté pilotes.
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
    darkone.security.kernel-params.enable = lib.mkEnableOption "Active les paramètres noyau dynamiques ANSSI (R8–R14).";
  };

  config = lib.mkMerge [
    { darkone.security.kernel-params.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R8 — Options mémoire à la ligne de commande (intermediary, base)
        # sideEffects: init_on_* ~1-3% CPU, nosmt ~-30% multi-thread, debugfs=off casse perf
        (lib.mkIf (isActive "R8" "intermediary" "base" [ ]) {
          boot.kernelParams = [
            "l1tf=full,force" # L1 Terminal Fault : mitigation complète + SMT désactivé
            "page_poison=on" # Empoisonnement des pages libérées
            "pti=on" # Page Table Isolation (Meltdown)
            "slab_nomerge=yes" # Pas de fusion slab (complexifie heap overflow)
            "slub_debug=FZP" # Debug slab : Freelist / Zero / Poison
            "spec_store_bypass_disable=seccomp" # Spectre v4 via seccomp
            "spectre_v2=on" # Spectre v2
            "mds=full,nosmt" # MDS + désactivation SMT
            "mce=0" # Panic sur MCE non corrigé
            "page_alloc.shuffle=1" # Randomisation allocateur de pages
            "rng_core.default_quality=500" # Qualité HWRNG pour CSPRNG
            "init_on_alloc=1" # Effacement mémoire à l'allocation
            "init_on_free=1" # Effacement mémoire à la libération
            "randomize_kstack_offset=on" # ASLR pile noyau
            "vsyscall=none" # Désactiver vsyscall legacy
            "mitigations=auto,nosmt" # Toutes vulns CPU (ceinture-bretelles)
            "debugfs=off" # Interdire /sys/kernel/debug
          ];
        })

        # R9 — Sysctls noyau (intermediary, base)
        # sideEffects: unprivileged_userns_clone=0 casse Docker/Podman rootless, Flatpak
        (lib.mkIf (isActive "R9" "intermediary" "base" [ ]) {
          boot.kernel.sysctl = {
            # Mémoire et processus
            "kernel.kexec_load_disabled" = 1; # Désactiver kexec (sauf tag needs-kexec)
            "kernel.unprivileged_userns_clone" = 0; # linux-hardened : pas d'userns non-privil.
            "kernel.core_uses_pid" = 1; # core dump avec PID dans le nom
            "vm.unprivileged_userfaultfd" = 0; # Interdire userfaultfd non-privilégié
            "kernel.kptr_restrict" = 2; # Cacher les pointeurs kernel (/proc/kallsyms)
            "kernel.io_uring_disabled" = 2; # Interdire io_uring sauf root
            "dev.tty.ldisc_autoload" = 0; # Pas de chargement automatique ldisc
            "dev.tty.legacy_tiocsti" = 0; # Interdire l'injection TIOCSTI
            "kernel.perf_event_paranoid" = 3; # Restreindre perf_events aux admins
            "kernel.panic_on_oops" = 1; # Panic sur kernel oops
            "kernel.dmesg_restrict" = 1; # Restreindre dmesg aux admins

            # Réseau général
            "net.core.bpf_jit_harden" = 2; # Durcir le JIT BPF
          };
        })

        # R10 — Désactiver le chargement de modules (reinforced, base, tag: disable-kernel-module-loading)
        # sideEffects: impossible d'ajouter un périphérique sans reboot
        (lib.mkIf (isActive "R10" "reinforced" "base" [ "disable-kernel-module-loading" ]) {
          boot.kernel.sysctl."kernel.modules_disabled" = 1;

          # PRÉREQUIS : lister tous les modules requis dans boot.kernelModules
          # et boot.initrd.kernelModules avant l'activation de cette règle.
          # TODO: assertion NixOS vérifiant que boot.kernelModules est non vide
        })

        # R11 — Activer Yama (intermediary, base)
        # sideEffects: ptrace_scope=2 empêche gdb/strace non-root ; =3 même pour root
        (lib.mkIf (isActive "R11" "intermediary" "base" [ ]) {

          # Niveau reinforced : ptrace_scope=2, niveau high : 3
          boot.kernel.sysctl."kernel.yama.ptrace_scope" =
            if dnfLib.levelMapping.${mainSecurityCfg.level} >= dnfLib.levelMapping."reinforced" then 2 else 1;
          # La LSM stack complète est configurée dans complement.nix (C2)
        })

        # R12 — Sysctls réseau IPv4 (intermediary, base)
        # sideEffects: arp_filter=1 peut casser VRRP/keepalived multi-interfaces
        (lib.mkIf (isActive "R12" "intermediary" "base" [ ]) {
          boot.kernel.sysctl = {

            # Antispoofing et filtrage
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

            # Journalisation
            "net.ipv4.conf.all.log_martians" = 1;
            "net.ipv4.conf.default.log_martians" = 1;

            # TCP
            "net.ipv4.tcp_syncookies" = 1; # Protection SYN flood
            "net.ipv4.tcp_timestamps" = 0; # Pas de timestamps (fingerprintabilité)
            "net.ipv4.tcp_sack" = 1; # SACK activé (anti-DoS SACK panic noyau >5.4)
          };
        })

        # R13 — Désactiver IPv6 (intermediary, base, tag: no-ipv6)
        # sideEffects: casse les services IPv6-only (Cloudflare, AWS Egress-only)
        # Note: par défaut inactive (tag absent). Préférer un durcissement IPv6 à la désactivation.
        (lib.mkIf (isActive "R13" "intermediary" "base" [ "no-ipv6" ]) {
          networking.enableIPv6 = false;
          boot.kernelParams = [ "ipv6.disable=1" ];
          boot.kernel.sysctl = {
            "net.ipv6.conf.all.disable_ipv6" = 1;
            "net.ipv6.conf.default.disable_ipv6" = 1;
          };
        })

        # R14 — Sysctls systèmes de fichiers (intermediary, base)
        # sideEffects: protected_regular=2 peut casser des daemons créant des fichiers dans /tmp
        (lib.mkIf (isActive "R14" "intermediary" "base" [ ]) {
          boot.kernel.sysctl = {
            "fs.protected_hardlinks" = 1; # Interdire les hardlinks vers fichiers non-possédés
            "fs.protected_symlinks" = 1; # Interdire les symlinks dans sticky dirs
            "fs.protected_fifos" = 2; # Protéger les FIFOs dans sticky dirs
            "fs.protected_regular" = 2; # Protéger les fichiers réguliers dans sticky dirs
            "fs.suid_dumpable" = 0; # Pas de core dump pour les setuid
          }

          # binfmt_misc désactivé sauf si tag needs-binfmt présent (cohérent avec R23)
          // lib.optionalAttrs (!(lib.elem "needs-binfmt" mainSecurityCfg.excludes)) {
            "fs.binfmt_misc.status" = 0;
          };
        })
      ]
    ))
  ];
}
