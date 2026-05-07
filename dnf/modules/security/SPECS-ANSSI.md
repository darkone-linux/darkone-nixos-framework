# Spécifications techniques — Module NixOS de conformité ANSSI-BP-028 v2.0

## 1. Objet

Ce document décrit la conception d'un module NixOS implémentant les [Recommandations
de configuration d'un système GNU/Linux](https://messervices.cyber.gouv.fr/guides/recommandations-de-securite-relatives-un-systeme-gnulinux) publiées par l'ANSSI (référentiel
**ANSSI-BP-028 v2.0**, 03/10/2022). Pour chaque recommandation R*N* dont une
implémentation déclarative est possible, on précise :

1. une description succincte (lorsque pertinent) ;
2. ce qui peut être implémenté dans la configuration NixOS ;
3. la procédure de validation (commande shell ou test programmable en Rust) ;
4. le niveau de durcissement ANSSI ciblé par la règle / l'implémentation ;
5. *(optionnel)* les contraintes opérationnelles et effets de bord induits.

> [!NOTE]
> Ces informations font ponctuellement référence à [l'implémentation du module anssi du projet Sécurix](https://github.com/cloud-gouv/securix/tree/main/modules/anssi).

L'écriture des `checkScript` (shell) ou des analogues Rust est laissée pour une
phase ultérieure ; ce document constitue la *grille de spécification* à partir
de laquelle ces scripts seront produits.

Le document complète aussi le guide par les mesures de l'**Annexe A** (patchs
linux-hardened, Lockdown LSM) et par des durcissements transverses (USBGuard,
nftables, SSH, LUKS, NTP/NTS, DNSSEC…) qui, sans être numérotés ANSSI, sont
indispensables à un système conforme à l'esprit du guide. Ils sont regroupés en
§ 3.17 sous l'identifiant `Cn` (`C` pour *complement*).

## 2. Architecture du module

Le module est organisé sous `security.anssi.*` et reprend la structure existante
du module `anssi/` (`options.nix`, `generator.nix`, `ruleset.nix`, …). Chaque règle
est exprimée dans un fichier thématique exposant un *attribute set*
`{ R<N> = { … }; … }`. La forme attendue d'une règle suit le contrat déjà décrit
en commentaire dans `options.nix:24-32` :

```nix
{
  name          = "RXX_ShortName";
  anssiRef      = "RXX – Titre français de la recommandation";
  description   = "…";
  severity      = "minimal" | "intermediary" | "reinforced" | "high";
  category      = "base" | "client" | "server";
  tags          = [ … ];                  # optionnel
  architectures = [ "x86_64" "aarch64" ]; # optionnel
  config        = f: { … };               # contributions au système NixOS
  checkScript   = pkgs: pkgs.writeShellScript "check-RXX" ''…''; # validation
  implementations = { … };                # variantes (ex. secureboot vs grub)
  sideEffects   = [ "…" ];                # optionnel, pour reporting
}
```

Le champ `sideEffects` (nouveau) est libre ; il est repris dans le rapport de
conformité (`org.securix.anssi-compliance.v1.rules[].sideEffects`) afin que
l'opérateur connaisse les conséquences de l'activation.

### 2.1 Niveaux de durcissement

Le mapping `levelMapping` (`options.nix:17`) reprend la grille MIRE :

| Niveau ANSSI | Clé NixOS       | Pondération | Usage typique                    |
| ------------ | --------------- | ----------- | -------------------------------- |
| Minimal      | `minimal`       | 0           | Tout système                     |
| Intermédiaire| `intermediary`  | 1           | Quasi-tout système               |
| Renforcé     | `reinforced`    | 2           | Forte sensibilité, multi-tenant  |
| Élevé        | `high`          | 3           | Compétences et budget dédiés     |

Une règle est activée ssi `cfg.enable && niveau_courant ≥ severity_règle &&
catégorie_compatible && aucun_tag_exclu && architecture_compatible &&
aucune_exception_explicite`.

### 2.2 Catégories

- `base` : règles applicables à tous les systèmes ;
- `client` : poste utilisateur (env. graphique, gestion de session, USB, son) ;
- `server` : serveur (durcissement réseau, journalisation centralisée…).

### 2.3 Tags d'exclusion

Tags suggérés (utilisables dans `excludes`) :

- `kernel-recompile` : règles imposant de recompiler le noyau (R15–R27, C1, C2) ;
- `disable-kernel-module-loading` : R10 (peut casser certains systèmes) ;
- `no-ipv6` : R13, R22 ;
- `no-mac` : pas de MAC actif (renvoie aux exceptions par défaut) ;
- `no-sealing` : pas de scellement / HIDS (R76, R77) ;
- `no-auditd` : auditd non configurable (R73) ;
- `embedded` : système embarqué (lève les contraintes /var, /home, etc.) ;
- `needs-jit` : autorise W^X relâché pour JIT (Java, .NET, V8, Wasm) ;
- `needs-kexec` : conserve `kexec` pour kdump ;
- `needs-binfmt` : conserve `binfmt_misc` (Java, qemu-static) ;
- `needs-hibernation` : conserve l'hibernation (laptop) ;
- `needs-usb-hotplug` : ne pas activer USBGuard / `kernel.deny_new_usb`.

### 2.4 Format du rapport de conformité

Le module produit déjà :

- `system.build.complianceReport` : structure Nix sérialisable
  (`org.securix.anssi-compliance.v1`) ;
- `system.build.complianceReportDocument` : JSON équivalent ;
- `system.build.complianceCheckScript` (binaire `anssi-nixos-compliance-check`) :
  exécute les `checkScript` activés et affiche un tableau coloré.

Évolutions à prévoir :

- ajout d'un champ `sideEffects` par règle ;
- ajout d'un champ `mitreLevel` (`M`, `I`, `R`, `E`) en complément de
  `severity` afin d'afficher la grille MIRE telle quelle ;
- export Markdown `system.build.complianceReportMarkdown` pour audit.

### 2.5 Découpage en fichiers

| Fichier                  | Recommandations                  |
| ------------------------ | -------------------------------- |
| `preboot.nix`            | R1–R7                            |
| `kernel-options.nix`     | R8–R14                           |
| `kernel.nix`             | R15–R27                          |
| `vfs.nix`                | R28, R29, R50–R57                |
| `users.nix`              | R30–R36                          |
| `mac.nix`                | R37 (méta MAC)                   |
| `apparmor.nix`           | R45                              |
| `selinux.nix`            | R46–R49                          |
| `sudo.nix`               | R38–R44                          |
| `packages.nix`           | R58–R61                          |
| `services.nix`           | R62–R66                          |
| `pam.nix`                | R67, R68                         |
| `nss.nix`                | R69, R70                         |
| `journaling.nix`         | R71–R73                          |
| `mta.nix`                | R74, R75                         |
| `integrity.nix`          | R76, R77                         |
| `network-services.nix`   | R78–R80                          |
| `complement.nix`         | C1–C12 (cross-cutting, Annexe A) |

### 2.6 Implémentation des contrôles

Deux familles de `checkScript` co-existent :

- **Shell POSIX/bash** (mode actuel) : court, sans dépendance, exécuté par
  `anssi-nixos-compliance-check`.
- **Rust** (recommandé pour les contrôles complexes) : un binaire
  `anssi-validator` (cargo workspace dans `pkgs/anssi-validator/`) exposera
  une commande par règle (`anssi-validator check R12 --json`). Il sera empaqueté
  via `pkgs.rustPlatform.buildRustPackage` puis injecté dans
  `system.build.complianceCheckScript` à la place du shell pour les règles dont
  le contrôle est tabulaire (parsing de `/proc`, comparaison de configurations,
  scellement, droits FS récursifs…). Chaque `checkScript` indique soit un shell
  soit `pkgs.anssi-validator + " check RXX"`.

Conventions de sortie communes :

- code `0` ⇒ conforme ;
- code `1` ⇒ non-conforme ;
- code `2` ⇒ indéterminé (matériel manquant, hors-périmètre…) ;
- code `3` ⇒ erreur d'exécution du contrôle (panne d'outil) ;
- toute ligne contenant `WARNING`, `fail`, `error`, `UNSET`, `DIVERGENCE` ou
  `incomplete` est colorée en rouge par le wrapper.

### 2.7 Politique transverse

Quelques exigences ne peuvent pas être portées par une règle isolée mais doivent
être imposées globalement :

- **Stack LSM ordonnée** (`boot.kernelParams = [ "lsm=lockdown,yama,bpf,…" ]`) :
  fixée par § 3.17/C2 ; influe sur R10, R11, R20.
- **`networking.firewall` en politique deny-by-default** : posée par C4 ; sert
  d'invariant pour R74, R78–R80.
- **Pas de mots de passe en clair dans le store Nix** : assertion globale qui
  refuse `users.users.<u>.hashedPassword` autre que `null` ou `"!"` ; les
  mots de passe doivent passer par `agenix`/`sops-nix` (cf. R51, R68).
- **Reproductibilité** : `boot.kernelPatches` et tout patch utilisateur doivent
  être référencés par hash (assertion sur `lib.isStorePath`).

---

## 3. Recommandations

### 3.1 Configuration matérielle

#### R1 — Choisir et configurer son matériel
- **Description** : applique la note ANSSI-NT-024 sur la configuration matérielle x86.
- **Sévérité** : `high` · **Catégorie** : `base`.
- **Implémentation NixOS** : aucune, action externe au système. Possibilité
  d'exposer `security.anssi.hardwareBaseline.{vendor,model,fwVersion}` pour
  documenter la configuration validée.
- **Validation** : impossible automatiquement ; `checkScript` retourne
  `TODO: hardware configuration audited manually` (code 2). Un futur module
  pourra croiser `dmidecode -t bios` et un *baseline* signé.
- **Contraintes / effets induits** : aucun direct ; nécessite un processus
  d'achat et d'audit hors-bande.

#### R2 — Configurer le BIOS/UEFI
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : aucune (configuration firmware).
- **Validation** : `checkScript` listant les variables critiques accessibles en
  EFI runtime : présence de `/sys/firmware/efi`, `bootctl status`,
  `fwupdmgr get-devices`, `mokutil --sb-state`. Sortie informative,
  code retour 2 par défaut. À combiner avec `chipsec` (paquet
  `pkgs.chipsec`) pour audit approfondi.
- **Contraintes / effets induits** : `chipsec` requiert `CONFIG_DEVMEM` ou un
  module noyau dédié ; donc à n'utiliser qu'en mode audit, pas en exploitation.

#### R3 — Activer le démarrage sécurisé UEFI
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** :
  - `boot.loader.systemd-boot.enable = true;`
  - intégration recommandée de **lanzaboote** :
    `boot.lanzaboote = { enable = true; pkiBundle = "/var/lib/sbctl"; };`
    et désactiver `systemd-boot.enable` dans ce cas (mutuellement exclusif).
  - `boot.loader.efi.canTouchEfiVariables = true;` côté provisioning.
- **Validation** :
  ```sh
  test -d /sys/firmware/efi && \
  xxd -p -c4 /sys/firmware/efi/efivars/SecureBoot-* | grep -q '01$'
  bootctl status | grep -i 'secure boot'
  mokutil --sb-state 2>/dev/null
  ```
- **Niveau** : intermédiaire ; le passage à `high` exige R4 + R6.
- **Contraintes / effets induits** : modules tiers (NVIDIA propriétaire, VirtualBox,
  ZFS *out-of-tree*) doivent être signés ; sinon ne se chargent plus. Le passage
  à lanzaboote nécessite un premier *enroll-keys* en physique ou via
  `sbctl enroll-keys --microsoft` (compromis pratique mais conserve l'autorité
  Microsoft).

#### R4 — Remplacer les clés préchargées
- **Sévérité** : `high`.
- **Implémentation NixOS** : via lanzaboote :
  ```sh
  sbctl create-keys
  sbctl enroll-keys --yes-this-might-brick-my-machine     # pas de Microsoft
  ```
  Clés conservées hors-store dans `/var/lib/sbctl` (chiffré, sauvegardé). Pour
  un parc, gérer une PKI dédiée (`step-ca` ou Smallstep, Vault PKI) signant les
  binaires UEFI et noyaux.
- **Validation** : `sbctl status`, `efi-readvar -v PK | head` et comparaison
  d'empreintes contre une *baseline* fournie via
  `security.anssi.expectedSecureBootKeys` (option ad hoc, hash SHA-256).
- **Contraintes / effets induits** : risque de *brickage* si la machine ne
  permet pas la restauration des clés OEM (touche `Reset to defaults` absente).
  Procédure de récupération obligatoire (clé USB de réenrôlement scellée) ;
  plus possible de booter une distro tierce sans la signer avec la nouvelle PK.

#### R5 — Mot de passe pour le chargeur de démarrage
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** (via le mécanisme `implementations`) :
  - `grub` : `boot.loader.grub.users."admin" = { hashedPasswordFile = …; };`
    et `boot.loader.grub.extraConfig = "set superusers=\"admin\"\n";`.
  - `secureboot` : remplit l'objectif via R3 + R4 (le menu n'est plus
    modifiable car la cmdline est signée), `depends = [ "R3" "R6" ]`.
  - `systemd-boot` : pas de mot de passe natif → forcer `secureboot`.
- **Validation** :
  - GRUB : `grep -q '^password_pbkdf2' /boot/grub/grub.cfg` ;
  - secureboot : déléguée à R3/R4 (UKI signée).
- **Contraintes / effets induits** : sur GRUB, oublier le mot de passe oblige
  un démarrage en *rescue media*. Toujours stocker une copie du hash dans le
  coffre.

#### R6 — Protéger la cmdline du noyau et l'initramfs
- **Sévérité** : `high`.
- **Implémentation NixOS** :
  - construction d'une *Unified Kernel Image* (UKI) signée. Avec lanzaboote,
    natif ; sinon `boot.uki.enable = true;` (NixOS ≥ 24.05) +
    `boot.loader.systemd-boot.unifiedKernelImages = true;`.
  - `boot.initrd.systemd.enable = true;` pour un initramfs déterministe.
  - chiffrer la partition `/boot` via LUKS2 *detached header* (cf. C6) si
    Secure Boot non disponible.
- **Validation** :
  ```sh
  bootctl list --json=short | jq '.[] | select(.type=="uki")'
  sbverify --list /boot/EFI/Linux/*.efi
  ```
- **Contraintes / effets induits** : modifier la cmdline (debug noyau) impose
  une re-signature. Les initramfs générés par les modules tiers (`zfsbootmenu`,
  `dracut` overlay) doivent passer par le pipeline Nix pour rester signés.

#### R7 — Activer l'IOMMU
- **Sévérité** : `reinforced`.
- **Implémentation NixOS** : `boot.kernelParams` ajoute, selon
  `pkgs.stdenv.hostPlatform.parsed.cpu.vendor` :
  - Intel : `[ "intel_iommu=on" "iommu=force" "iommu.passthrough=0" "iommu.strict=1" ]`
  - AMD : `[ "amd_iommu=on" "iommu=force" "iommu.passthrough=0" "iommu.strict=1" ]`
  - ARM : `[ "iommu.passthrough=0" ]` (l'IOMMU est généralement piloté par DT).
- **Validation** :
  ```sh
  ls /sys/class/iommu | grep -q .
  dmesg | grep -iE 'IOMMU enabled|DMAR|AMD-Vi'
  ```
- **Contraintes / effets induits** : peut provoquer des plantages avec des
  GPU/cartes Thunderbolt mal supportés ; surcoût latence I/O ~5–15 % sur
  baies NVMe à très haut débit ; certaines machines virtuelles imbriquées
  doivent être configurées avec `vfio` cohérent.

### 3.2 Configuration dynamique du noyau

#### R8 — Options mémoire à la ligne de commande
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : `boot.kernelParams` (déjà `kernel-options.nix:34-47`).
  Compléter avec :
  - `init_on_alloc=1`, `init_on_free=1` (effacement mémoire systématique) ;
  - `randomize_kstack_offset=on` (ASLR pile noyau) ;
  - `vsyscall=none` (en plus de R15 statique) ;
  - `mitigations=auto,nosmt` (ceinture-bretelles toutes vulns CPU) ;
  - `extra_latent_entropy` (linux-hardened, cf. C1) ;
  - `debugfs=off` (interdit `/sys/kernel/debug`).
- **Validation** : comparaison ligne par ligne des paramètres attendus avec
  `/proc/cmdline` (déjà fait). Compléter par `lscpu | grep Vulnerability`
  (toute ligne `Vulnerable` → fail).
- **Contraintes / effets induits** : `init_on_*` coûte ~1–3 % CPU mémoire-bound ;
  `mitigations=auto,nosmt` désactive l'hyperthreading (≈ -30 % throughput
  multi-thread) ; `debugfs=off` casse certains outils de profilage (perf
  events) et drivers anciens.

#### R9 — Sysctls noyau
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : `boot.kernel.sysctl` (déjà `kernel-options.nix:107-153`).
  Compléter par :
  - `kernel.kexec_load_disabled = 1` ;
  - `kernel.unprivileged_userns_clone = 0` (linux-hardened) ;
  - `kernel.core_uses_pid = 1` ;
  - `vm.unprivileged_userfaultfd = 0` ;
  - `kernel.kptr_restrict = 2` (déjà) ;
  - `kernel.io_uring_disabled = 2` (interdit io_uring sauf privilégiés) ;
  - `dev.tty.ldisc_autoload = 0` ;
  - `dev.tty.legacy_tiocsti = 0` (cf. C1).
- **Validation** : `mkSysctlChecker` (existant). Étendre avec lecture directe
  de `/proc/sys/...` pour les plates-formes où `sysctl` est absent.
- **Contraintes / effets induits** : `unprivileged_userns_clone=0` casse Docker
  rootless, Podman rootless, *bubblewrap* non-suid, Flatpak ; à concilier avec
  R66. `io_uring_disabled=2` casse certains stacks haute perf (ScyllaDB).

#### R10 — Désactiver le chargement de modules
- **Sévérité** : `reinforced` · tag : `disable-kernel-module-loading`.
- **Implémentation NixOS** :
  - `boot.kernel.sysctl."kernel.modules_disabled" = 1;`
  - lister tous les modules requis dans `boot.kernelModules` et
    `boot.initrd.kernelModules` avant l'activation ;
  - alternative équivalente plus stricte : compiler un noyau **monolithique**
    (`CONFIG_MODULES=n`, cf. R23 variante).
- **Validation** :
  ```sh
  [ "$(sysctl -n kernel.modules_disabled)" = 1 ]
  diff <(awk '{print $1}' /proc/modules | sort) \
       <(printf '%s\n' "${MODULES_ATTENDUS[@]}" | sort)
  ```
  Couverture par Rust : croisement avec `config.boot.kernelModules`.
- **Contraintes / effets induits** : impossible de brancher un nouveau
  périphérique requérant un module non chargé (impression, Wi-Fi USB, ZFS
  *first mount*). Tout changement matériel impose un *reboot*. Mutuellement
  exclusif avec `nixos-rebuild switch` côté pilotes (le nouveau noyau doit
  être démarré pour activer un nouveau module).

#### R11 — Activer Yama
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** :
  - LSM stack global : `boot.kernelParams = [ "lsm=lockdown,yama,bpf,landlock,…" ];`
    (cf. § 2.7 et C2) ;
  - `boot.kernel.sysctl."kernel.yama.ptrace_scope" = 2;` (renforcé : `3`).
- **Validation** :
  ```sh
  cat /sys/kernel/security/lsm | tr ',' '\n' | grep -q '^yama$'
  [ "$(sysctl -n kernel.yama.ptrace_scope)" -ge 2 ]
  ```
- **Niveau** : intermédiaire (`1`) → renforcé (`2`/`3`).
- **Contraintes / effets induits** : `=2` empêche `gdb`/`strace`/`perf` non-root,
  outils de débogage n'opèrent qu'en root ; `=3` interdit `ptrace` y compris
  pour root (analyse de crash plus difficile).

#### R12 — Sysctls réseau IPv4
- **Sévérité** : `intermediary` · **Catégorie** : `base`.
- **Implémentation NixOS** : `boot.kernel.sysctl` (déjà
  `kernel-options.nix:189-256`). Ajouter :
  - `net.ipv4.tcp_timestamps = 0` (sauf si métrologie nécessaire) ;
  - `net.ipv4.tcp_sack = 1` (anti-DoS *SACK panic* : noyau >5.4 OK) ;
  - `net.ipv4.conf.all.log_martians = 1` ;
  - `net.ipv4.conf.default.log_martians = 1` ;
  - `net.ipv4.icmp_echo_ignore_broadcasts = 1`.
- **Validation** : `mkSysctlChecker`. Implémentation Rust avec table de
  référence et tolérance au dual-stack.
- **Contraintes / effets induits** : `arp_filter=1` peut casser les
  configurations multi-interfaces avec VRRP/keepalived ; `accept_redirects=0`
  casse certains setups *route_to_remote* en cluster.

#### R13 — Désactiver IPv6
- **Sévérité** : `intermediary` · tag : `no-ipv6`.
- **Implémentation NixOS** :
  - `networking.enableIPv6 = false;`
  - `boot.kernelParams = [ "ipv6.disable=1" ];`
  - sysctls existants (`kernel-options.nix:259-283`).
- **Validation** :
  ```sh
  [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = 1 ]
  ip -6 addr show | grep -v 'inet6 ::1' | grep -q inet6 && exit 1
  ```
- **Niveau** : intermédiaire (appliquée seulement si tag actif).
- **Contraintes / effets induits** : casse les services *IPv6-only* (Cloudflare,
  certains miroirs Debian, AWS Egress-only). En contexte mixte, **préférer
  un durcissement IPv6** plutôt que la désactivation ; c'est la posture par
  défaut du module (tag absent ⇒ R13 désactivée).

#### R14 — Sysctls systèmes de fichiers
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : déjà couvert (`kernel-options.nix:285-316`).
  Corriger la coquille `protected_hardinks` → `fs.protected_hardlinks` ;
  ajouter `fs.binfmt_misc.status = 0` (cohérent avec R23) si tag
  `needs-binfmt` absent.
- **Validation** : `mkSysctlChecker`.
- **Contraintes / effets induits** : `protected_regular=2` peut casser des
  daemons qui créent des fichiers dans `/tmp` qu'ils ne possèdent pas (rare).

### 3.3 Configuration statique (recompilation noyau)

> Toutes les règles R15–R27 nécessitent un noyau personnalisé. NixOS le permet
> via `boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.linux_X.override {
> structuredExtraConfig = with lib.kernel; { … }; })`. Tag d'exclusion :
> `kernel-recompile`.
>
> **Effets induits transverses** : pas de cache binaire NixOS (≈ 30–60 min de
> compilation par mise à jour selon CPU), gestion d'une PKI noyau (R18),
> charge de veille CVE supplémentaire. Ces règles doivent être réservées à
> un parc géré par un MCO outillé.

#### R15 — Options de compilation gestion mémoire
- **Sévérité** : `high`.
- **Implémentation** : `structuredExtraConfig = { STRICT_KERNEL_RWX = yes;
  DEBUG_WX = yes; STACKPROTECTOR_STRONG = yes; HARDENED_USERCOPY = yes;
  VMAP_STACK = yes; FORTIFY_SOURCE = yes; SCHED_STACK_END_CHECK = yes;
  DEVMEM = no; DEVKMEM = no; PROC_KCORE = no; LEGACY_VSYSCALL_NONE = yes;
  COMPAT_VDSO = no; SECURITY_DMESG_RESTRICT = yes; RETPOLINE = yes;
  REFCOUNT_FULL = yes; }`.
- **Validation** : lecture de `/proc/config.gz` (`zcat /proc/config.gz`) ou
  `/boot/config-$(uname -r)`. Comparaison via Rust contre table attendue.
- **Contraintes / effets induits** : `REFCOUNT_FULL=y` → ~1 % CPU sur charge
  système ; `HARDENED_USERCOPY=y` casse certains anciens drivers binaires.

#### R16 — Structures de données
- **Sévérité** : `high`.
- **Implémentation** : `DEBUG_CREDENTIALS = yes; DEBUG_NOTIFIERS = yes;
  DEBUG_LIST = yes; DEBUG_SG = yes; BUG_ON_DATA_CORRUPTION = yes;`.
- **Validation** : idem R15 (config noyau).
- **Contraintes / effets induits** : surcoût CPU 2–5 % en charge syscall
  intensive ; *kernel panic* assuré sur corruption détectée (souhaitable mais
  augmente la fréquence d'arrêt sur matériel défaillant — ECC obligatoire).

#### R17 — Allocateur mémoire
- **Sévérité** : `high`.
- **Implémentation** : `SLAB_FREELIST_RANDOM = yes; SLUB = yes;
  SLAB_FREELIST_HARDENED = yes; SLAB_MERGE_DEFAULT = no; SLUB_DEBUG = yes;
  PAGE_POISONING = yes; PAGE_POISONING_NO_SANITY = yes;
  PAGE_POISONING_ZERO = yes; COMPAT_BRK = no;`.
- **Validation** : config noyau + `dmesg | grep -i 'SLUB:'`.
- **Contraintes / effets induits** : `PAGE_POISONING` ajoute ~3–5 % de
  consommation CPU lors des allocations massives ; mémoire un peu plus
  fragmentée (pas de fusion SLAB).

#### R18 — Modules signés
- **Sévérité** : `high`.
- **Implémentation** : `MODULES = yes; MODULE_SIG = yes; MODULE_SIG_FORCE = yes;
  MODULE_SIG_ALL = yes; MODULE_SIG_SHA512 = yes;`. Clé via
  `MODULE_SIG_KEY = "/var/lib/anssi-mod-signing.pem";` (gérée hors-store via
  `agenix`/`sops-nix`). Pour modules tiers (DKMS, ZFS) : intégrer dans le
  pipeline Nix (`pkgs.linuxPackages_custom`).
- **Validation** :
  ```sh
  for m in $(awk '{print $1}' /proc/modules); do
    modinfo "$m" 2>/dev/null | grep -q '^signature:' || echo "WARNING:$m unsigned"
  done
  ```
- **Contraintes / effets induits** : tout module *out-of-tree* (NVIDIA, ZFS,
  VirtualBox, v4l2loopback…) doit être signé localement → pipeline de build
  obligatoire ; clé privée à protéger (cible privilégiée).

#### R19 — Réactions aux évènements anormaux
- **Sévérité** : `high`.
- **Implémentation** : `BUG = yes; PANIC_ON_OOPS = yes; PANIC_TIMEOUT =
  freeform "-1";`. Conserver `kernel.panic_on_oops = 1` (R9).
- **Validation** : config noyau ; `cat /proc/sys/kernel/panic`.
- **Contraintes / effets induits** : `PANIC_TIMEOUT=-1` interdit le redémarrage
  automatique ⇒ machine inopérante après un *oops* jusqu'à intervention
  humaine. Sur serveur sans astreinte 24/7, prévoir un *watchdog* externe.

#### R20 — Primitives LSM
- **Sévérité** : `high`.
- **Implémentation** : `SECCOMP = yes; SECCOMP_FILTER = yes; SECURITY = yes;
  SECURITY_YAMA = yes; SECURITY_LANDLOCK = yes; SECURITY_LOCKDOWN_LSM = yes;
  SECURITY_LOCKDOWN_LSM_EARLY = yes; SECURITY_WRITABLE_HOOKS = no;`.
- **Validation** : `cat /sys/kernel/security/lsm` doit lister
  `lockdown,yama,seccomp,landlock`.
- **Contraintes / effets induits** : Lockdown actif (cf. C2) interdit
  `/dev/mem`, `kexec`, MSR write ; à concilier avec les outils de bas niveau
  (`flashrom`, `i2c-tools` privilégiés…).

#### R21 — Plugins GCC
- **Sévérité** : `high`.
- **Implémentation** : `GCC_PLUGINS = yes; GCC_PLUGIN_LATENT_ENTROPY = yes;
  GCC_PLUGIN_STACKLEAK = yes; GCC_PLUGIN_STRUCTLEAK = yes;
  GCC_PLUGIN_STRUCTLEAK_BYREF_ALL = yes; GCC_PLUGIN_RANDSTRUCT = yes;`.
  Désactivé sur Clang (`stdenv.cc.isClang`) ⇒ règle marquée *non
  applicable* avec rationale automatique.
- **Validation** : config noyau.
- **Contraintes / effets induits** : `RANDSTRUCT` impose de recompiler tous
  les modules contre la même graine (sinon refus de chargement) ; module
  binaire externe interdit ⇒ à coupler à R18.

#### R22 — Pile réseau
- **Sévérité** : `high`.
- **Implémentation** : `IPV6 = no` (sous tag `no-ipv6`) ;
  `SYN_COOKIES = yes;`. Si IPv6 conservé : `IPV6_PRIVACY = yes;
  IPV6_OPTIMISTIC_DAD = yes;`.
- **Validation** : config noyau ; `cat /proc/net/snmp | grep TcpExt`.
- **Contraintes / effets induits** : voir R13.

#### R23 — Comportements divers du noyau
- **Sévérité** : `high`.
- **Implémentation** : exposé en `implementations` :
  - `withoutModules` : `KEXEC = no; HIBERNATION = no; BINFMT_MISC = no;
    LEGACY_PTYS = no; MODULES = no;` (mutuellement exclusif avec R18).
  - `withModules` : idem mais `MODULES = yes;` (R18 reste applicable).
  Compléter par `X86_MSR = no;` (lockdown).
- **Validation** : config noyau.
- **Contraintes / effets induits** :
  - `KEXEC=n` ⇒ `kdump` impossible (collecter les crashes via console série).
    Tag `needs-kexec` lève la contrainte.
  - `HIBERNATION=n` ⇒ pas de *suspend-to-disk* (laptops) ; tag
    `needs-hibernation`.
  - `BINFMT_MISC=n` ⇒ pas de Java/.NET/qemu-user ; tag `needs-binfmt`.
  - `LEGACY_PTYS=n` ⇒ certains anciens *terminal multiplexers* cassent.

#### R24 — Spécificités x86 32 bits
- **Sévérité** : `high` · **Architectures** : `["i686"]`.
- **Implémentation** : `HIGHMEM64G = yes; X86_PAE = yes;
  DEFAULT_MMAP_MIN_ADDR = freeform "65536"; RANDOMIZE_BASE = yes;`.
- **Validation** : config noyau.
- **Contraintes / effets induits** : i686 obsolète, pratiquement aucun cas
  d'usage actuel ; règle conservée pour audit historique.

#### R25 — Spécificités x86_64
- **Sévérité** : `high` · **Architectures** : `["x86_64"]`.
- **Implémentation** : `X86_64 = yes; DEFAULT_MMAP_MIN_ADDR = freeform "65536";
  RANDOMIZE_BASE = yes; RANDOMIZE_MEMORY = yes; PAGE_TABLE_ISOLATION = yes;
  IA32_EMULATION = no; MODIFY_LDT_SYSCALL = no;`.
- **Validation** : config noyau ; `grep -q pti /proc/cpuinfo`.
- **Contraintes / effets induits** : `IA32_EMULATION=n` casse l'exécution
  des binaires 32 bits (Steam *runtime*, vieux jeux, certains pilotes
  propriétaires).

#### R26 — ARM 32 bits
- **Sévérité** : `high` · **Architectures** : `["arm"]`.
- **Implémentation** : `DEFAULT_MMAP_MIN_ADDR = freeform "32768";
  VMSPLIT_3G = yes; STRICT_MEMORY_RWX = yes; CPU_SW_DOMAIN_PAN = yes;
  OABI_COMPAT = no;`.
- **Validation** : config noyau.
- **Contraintes / effets induits** : `OABI_COMPAT=n` casse les très anciens
  binaires ARM ABI v3 (dépôts embedded vétustes).

#### R27 — ARM64
- **Sévérité** : `high` · **Architectures** : `["aarch64"]`.
- **Implémentation** : `DEFAULT_MMAP_MIN_ADDR = freeform "32768";
  RANDOMIZE_BASE = yes; ARM64_SW_TTBR0_PAN = yes;
  UNMAP_KERNEL_AT_EL0 = yes; ARM64_PTR_AUTH = yes; ARM64_BTI = yes;`.
- **Validation** : config noyau.
- **Contraintes / effets induits** : `PTR_AUTH`/`BTI` requièrent CPU ≥ ARMv8.3
  / 8.5 ; sur Cortex-A53/A72 anciens, ces options sont *no-op*.

### 3.4 Partitionnement et arborescence

#### R28 — Partitionnement type
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : ne porte que sur les *options de montage*
  (le partitionnement physique est défini par l'installation). Forcer dans
  `fileSystems`/`boot.specialFileSystems` :
  - `/tmp` : `boot.tmp.useTmpfs = true;` + options `nosuid,nodev,noexec`.
  - `/var/log`, `/var/tmp`, `/home`, `/srv`, `/opt` : ajouter
    `nosuid,nodev,noexec` (`nodev` seul pour `/usr` côté NixOS, en fait
    `/nix/store` impose `ro,nosuid,nodev` mais autorise `exec`).
  - `/proc` : `boot.specialFileSystems."/proc".options = [ "hidepid=2" "gid=proc" ];`
    + groupe `proc` créé via `users.groups.proc.gid = …`.
  - `/dev/shm` : `nosuid,nodev,noexec`.
  - `/run/user/<uid>` : `nosuid,nodev` (déjà imposé par systemd).
- **Validation** :
  ```sh
  findmnt -no TARGET,OPTIONS -t ext4,xfs,btrfs,tmpfs,zfs | \
    awk '$1=="/tmp"     && $2 !~ /nosuid/ {print "fail:" $0}
         $1=="/var/log" && $2 !~ /nosuid/ {print "fail:" $0}'
  ```
  Implémentation Rust : table `attendu[mountpoint] = [opts…]` puis croisement
  avec `mountinfo`.
- **Contraintes / effets induits** : `noexec /tmp` casse de nombreux
  installeurs/compilateurs (pip, cargo, gcc *temp objects*) → workaround par
  `TMPDIR=$XDG_RUNTIME_DIR` ou volume dédié sans `noexec`. `hidepid=2` masque
  les processus aux non-root ; certains outils (tmux, htop multi-user) doivent
  ajouter l'utilisateur au groupe `proc`.

#### R29 — Restreindre /boot
- **Sévérité** : `reinforced`.
- **Implémentation NixOS** :
  - `fileSystems."/boot".options = [ "nosuid" "nodev" "noexec" "noauto" ];`
  - droits : `system.activationScripts.bootPerm = ''chmod 0700 /boot'';`
  - `systemd.mounts` éphémère pendant `nixos-rebuild` (mount → switch →
    umount automatique).
- **Validation** :
  ```sh
  stat -c %a /boot              # attendu 700
  findmnt /boot                 # absent si noauto et démonté
  ```
- **Contraintes / effets induits** : `noauto` impose une mécanique de
  remontage à chaque mise à jour ; oublier de remonter casse le rollback de
  systemd-boot. Implémenter via un *wrapper* `nixos-rebuild` qui
  `systemctl start boot.mount` puis `systemctl stop` après build.

### 3.5 Comptes et authentification

#### R30 — Désactiver les comptes utilisateur inutilisés
- **Sévérité** : `minimal`.
- **Implémentation NixOS** : `users.mutableUsers = false;` puis énumérer
  uniquement les comptes nécessaires. Pour les comptes obsolètes :
  `users.users.<name>.shell = "${pkgs.shadow}/bin/nologin";`
  + `hashedPassword = "!"` ou `password = null`.
- **Validation** :
  ```sh
  awk -F: '($2!="*"&&$2!~"^!"&&$7!~"nologin|false") {print $1}' /etc/shadow
  ```
  doit ⊂ `security.anssi.allowedActiveUsers`.
- **Contraintes / effets induits** : `mutableUsers=false` interdit
  `passwd`/`useradd` ad hoc ⇒ toute évolution passe par le déploiement Nix.

#### R31 — Mots de passe robustes
- **Sévérité** : `minimal`.
- **Implémentation NixOS** : passe par PAM (R67/R68). Forcer
  `security.pam.services.passwd.rules.password.pwquality = { control = "required";
  modulePath = "${pkgs.libpwquality}/lib/security/pam_pwquality.so";
  args = [ "minlen=12" "minclass=3" "maxrepeat=1" "enforce_for_root" ]; };`
  Ajouter `pam_faillock` (cf. C10) : `deny=3 unlock_time=900` (15 min).
- **Validation** :
  ```sh
  grep -q 'pam_pwquality.*minlen=12' /etc/pam.d/passwd
  grep -q 'pam_faillock.*deny=3'     /etc/pam.d/system-auth
  ```
- **Contraintes / effets induits** : `enforce_for_root` interdit la
  réinitialisation du mot de passe root depuis le mode rescue sans satisfaire
  la complexité ; prévoir une procédure documentée.

#### R32 — Verrouillage sur inactivité
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** :
  - TTY : `programs.bash.loginShellInit = ''readonly TMOUT=600; export TMOUT'';`
    (export en `readonly` pour empêcher le contournement).
  - Console graphique :
    - GNOME : `services.xserver.displayManager.gdm.autoLockOnInactive = true;`
      ou `gsettings set org.gnome.desktop.session idle-delay 300`.
    - KDE : `qdbus org.freedesktop.ScreenSaver` pré-réglé.
    - Hyprland/sway : `swayidle` géré par le module, lock après 300 s.
  - Systemd : `loginctl enable-linger` désactivé pour les utilisateurs
    `client`.
- **Validation** :
  ```sh
  declare -p TMOUT | grep -q '^declare -rx TMOUT='
  loginctl show-session "$XDG_SESSION_ID" | grep -E '^IdleHint|^IdleSinceHint'
  ```
- **Contraintes / effets induits** : `TMOUT` peut tuer les sessions tmux/screen
  *foreground* sans backgrounding ⇒ documenter `tmux new-session -d`.

#### R33 — Imputabilité des actions d'administration
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** :
  - désactiver root : `users.users.root.hashedPassword = "!";`
    + `services.openssh.settings.PermitRootLogin = "no";`
  - sudo (R38–R44) avec journalisation `Defaults log_input,log_output,
    iolog_dir=/var/log/sudo-io`.
  - règles auditd (R73) : `-a exit,always -F arch=b64 -S execve,execveat`.
  - SSH : forcer `LogLevel = "VERBOSE"` (cf. C5) pour journaliser les
    empreintes de clé utilisées.
- **Validation** :
  ```sh
  passwd -S root | awk '$2!="L" && $2!="LK" {exit 1}'
  auditctl -l | grep -q execve
  test -d /var/log/sudo-io
  ```
- **Contraintes / effets induits** : I/O accru de quelques Mo/jour sur
  serveurs interactifs (sudo-io). Penser à la rotation et au chiffrement de
  ces journaux (R72).

#### R34 — Désactiver les comptes de service
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : `users.users.<svc>.isSystemUser = true;` (NixOS
  par défaut), `shell = "${pkgs.shadow}/bin/nologin"`, `hashedPassword = "!"`.
- **Validation** :
  ```sh
  awk -F: '$3<1000 && $7!~"nologin|false" && $1!="root" {print "fail:"$1}' /etc/passwd
  awk -F: '$3<1000 && $2!~"^[!*]" {print "fail:"$1}' /etc/shadow
  ```
- **Contraintes / effets induits** : aucun majeur, NixOS conforme.

#### R35 — Comptes de service uniques
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : assertion sur `config.systemd.services` listant
  les `serviceConfig.User` non-trivials et alertant sur les doublons (autre
  que `root`, qui doit lui-même être réservé). Interdire `User = "nobody"`
  (assertion stricte).
- **Validation** :
  ```sh
  systemctl show -p User '*.service' --value | sort | uniq -d
  ```
- **Contraintes / effets induits** : peut faire échouer le `nixos-rebuild`
  d'un système hérité si un service réutilise `nobody` ⇒ migration manuelle.

#### R36 — UMASK
- **Sévérité** : `reinforced`.
- **Implémentation NixOS** :
  - shells : `environment.etc."profile.d/anssi-umask.sh".text = "umask 0077";`
  - PAM : `security.pam.services.<svc>.makeHomeDir.umask = "0077";`
  - services systemd : `systemd.services.<svc>.serviceConfig.UMask = "0027";`
    posé par défaut via le helper `mkHardenedService`.
- **Validation** :
  ```sh
  bash -lc umask        # attendu 0077
  systemctl show '*.service' -p UMask | grep -vE 'UMask=00[27]7'
  ```
- **Contraintes / effets induits** : UMASK 0077 casse la collaboration via
  groupes (`/srv/share`) ; doc équipe : `chmod g+rwx <fichier>` explicite.

### 3.6 Contrôle d'accès obligatoire

#### R37 — Utiliser un MAC
- **Sévérité** : `reinforced`.
- **Implémentation NixOS** : règle « parapluie » : valide ssi au moins une
  R45/R46 active. Sur NixOS, AppArmor partiellement supporté (cf. exception
  `base.nix`). À défaut, exception explicite avec `rationale`.
- **Validation** : `cat /sys/kernel/security/lsm | grep -E 'apparmor|selinux'`.
- **Contraintes / effets induits** : aucune nouvelle ; report sur R45/R46.

#### R45 — AppArmor
- **Sévérité** : `reinforced`.
- **Implémentation NixOS** :
  - `security.apparmor.enable = true;`
  - `security.apparmor.policies` : profils en mode `enforce`.
  - profils empaquetés via `pkgs.apparmor-profiles` + profils maison
    versionnés dans `modules/apparmor/profiles/`.
- **Validation** :
  ```sh
  aa-status --enabled && aa-status | grep -q 'profiles are in enforce mode'
  aa-status --json | jq '.profiles | to_entries[] | select(.value!="enforce")'
  ```
- **Contraintes / effets induits** : NixOS dispose de peu de profils prêts à
  l'emploi (couverture < Ubuntu) ; chaque profil maison demande des tests de
  régression ; l'absence de profil pour un service exposé est un faux sentiment
  de sécurité (à signaler dans le rapport).

#### R46 — SELinux targeted enforcing
- **Sévérité** : `high`.
- **Implémentation NixOS** : non supporté (exception par défaut, `base.nix`).
- **Validation** : `getenforce` retournerait `Enforcing`. Le `checkScript`
  retourne `TODO: SELinux unsupported on NixOS` (code 2).
- **Contraintes / effets induits** : non applicable.

#### R47 — Confiner les utilisateurs interactifs
- **Sévérité** : `high`. Idem R46 (exception).

#### R48 — Variables booléennes SELinux
- **Sévérité** : `high`. Idem (exception).

#### R49 — Désinstaller les outils de debug SELinux
- **Sévérité** : `high`. Idem (exception). En contexte SELinux supporté :
  assertion que `setroubleshoot*` n'apparaît pas dans
  `environment.systemPackages`.

### 3.7 sudo

#### R38 — Groupe dédié sudo
- **Sévérité** : `reinforced`.
- **Implémentation NixOS** :
  - `security.sudo.execWheelOnly = true;` (sudo 4750 root:wheel) ;
  - création optionnelle `users.groups.sudoers` distinct de `wheel` pour
    séparer accès console / accès admin.
- **Validation** :
  ```sh
  stat -c '%a %U:%G' "$(readlink -f $(command -v sudo))"
  ```
- **Contraintes / effets induits** : un utilisateur retiré de `wheel` perd
  toute capacité sudo, même si une ligne `<user> ALL = …` existe ailleurs.

#### R39 — Directives sudo durcies
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** :
  ```nix
  security.sudo.extraConfig = ''
    Defaults  noexec, requiretty, use_pty, umask=0027
    Defaults  ignore_dot, env_reset
    Defaults  log_input, log_output, iolog_dir=/var/log/sudo-io
    Defaults  passwd_timeout=1, timestamp_timeout=5
    Defaults  rootpw                      # demande le pw root, pas le sien
    Defaults  mailto="${cfg.adminMailbox}", mail_badpass, mail_no_user
  '';
  ```
- **Validation** : `sudo -V | grep -E 'noexec|use_pty'` et grep sur
  `/etc/sudoers`.
- **Contraintes / effets induits** : `requiretty` fait échouer
  `ssh user@host sudo cmd` non-tty (option `-t` requise) ; `rootpw` impose
  un mot de passe root partagé entre admins → préférer `targetpw` ou rester
  sur `runaspw` selon politique.

#### R40 — Cibles non-root pour sudo
- **Sévérité** : `intermediary`.
- **Implémentation** : assertion sur `security.sudo.extraRules` interdisant
  `runAs = "root"` sauf liste explicite (`security.anssi.sudo.allowedRootRules`).
- **Validation** :
  ```sh
  awk '/runas_default/ || /\(root\)/' /etc/sudoers /etc/sudoers.d/*
  ```
- **Contraintes / effets induits** : alourdit la maintenance des règles
  (création de comptes intermédiaires `appsvc`) ; recommandé.

#### R41 — Limiter NOEXEC override
- **Sévérité** : `reinforced`.
- **Implémentation** : assertion : si une règle `extraRules` contient `EXEC:`,
  exiger `commands = [ … ]` non vides + commentaire `# anssi-exec-allowed`.
- **Validation** : `grep -P '\bEXEC:\s*$' /etc/sudoers.d/*` doit être vide.
- **Contraintes / effets induits** : empêche l'usage commode de `sudo -E env`
  pour scripts à variables d'environnement variables.

#### R42 — Bannir les négations
- **Sévérité** : `intermediary`.
- **Implémentation** : assertion : `!` interdit dans la liste des commandes.
- **Validation** : `grep -E '![^=]' /etc/sudoers /etc/sudoers.d/*`.
- **Contraintes / effets induits** : oblige une politique en allowlist
  exhaustive.

#### R43 — Préciser les arguments
- **Sévérité** : `intermediary`.
- **Implémentation** : Rust *parser sudoers* validant que chaque `Cmnd`
  comporte `Cmnd_Args` non vide.
- **Validation** : `cvtsudoers -f json /etc/sudoers` puis Rust check.
- **Contraintes / effets induits** : énormément de règles à écrire pour les
  commandes complexes (ex. `systemctl`) ; possibilité d'utiliser un wrapper
  shell signé pour réduire la complexité.

#### R44 — sudoedit
- **Sévérité** : `intermediary`.
- **Implémentation** : helper `mkSudoEditRule = file: { … }` ; assertion qui
  refuse `vi`/`vim`/`nano`/`emacs` comme cible directe.
- **Validation** : `grep -E '\b(vi|vim|nano|emacs)\b' /etc/sudoers.d/*` doit
  comporter `sudoedit`.
- **Contraintes / effets induits** : `sudoedit` impose `EDITOR` cohérent
  (variable d'environnement) ; documenter pour l'équipe.

### 3.8 Fichiers et répertoires

#### R50 — Restreindre les fichiers sensibles
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : NixOS pose 0640 root:shadow sur `/etc/shadow`.
  Compléter via `systemd.tmpfiles.settings` :
  - `/etc/audit`, `/var/log/audit`, `/var/log/sudo-io` : `0750 root:adm` ;
  - `/var/log/{nginx,sshd,...}` : `0640 syslog:adm` ;
  - GPG keyrings (`/var/lib/<svc>/.gnupg`) : `0700`.
- **Validation** :
  ```sh
  for f in /etc/shadow /etc/gshadow /etc/ssh/ssh_host_*_key \
           /etc/audit/auditd.conf; do
    perm=$(stat -c %a "$f"); [ "$perm" -le 640 ] || echo "fail:$f $perm"
  done
  ```
- **Contraintes / effets induits** : aucun majeur.

#### R51 — Changer les secrets dès l'installation
- **Sévérité** : `reinforced`.
- **Implémentation NixOS** : interdire toute `hashedPassword` en clair dans
  le store ; obligation `agenix`/`sops-nix`. Activation script vérifie
  qu'aucun hash ne figure dans une *blocklist* connue (`p4ssw0rd`, hash
  vide, hashs par défaut Debian/Ubuntu).
- **Validation** : Rust ; comparer `/etc/shadow` à la *blocklist* ;
  vérifier la fraîcheur (`chage -l`) et la rotation.
- **Contraintes / effets induits** : impose une infrastructure de gestion de
  secrets dès le bootstrap (impossible de déployer un nœud sans accès au
  coffre).

#### R52 — Sockets et pipes nommés
- **Sévérité** : `intermediary`.
- **Implémentation NixOS** : pour chaque service systemd, imposer
  `RuntimeDirectoryMode = "0750"` ; `Sockets` placés dans `/run/<service>/`
  et non dans `/tmp` ou `/var/run/` writable monde.
- **Validation** :
  ```sh
  ss -xlp | awk '{print $5}' | grep -E '^/(tmp|var/tmp)/' && exit 1
  find /run -type s -perm /o+rwx -ls
  ```
- **Contraintes / effets induits** : services historiques (X11 abstract socket)
  doivent migrer ou être documentés en exception.

#### R53 — Pas de fichiers sans propriétaire
- **Sévérité** : `minimal`.
- **Implémentation** : néant côté config ; *activation script* optionnel
  `find / -nouser -o -nogroup -exec chown root:root {} +` (mode
  remediation = `false` par défaut). Service `systemd.timers.anssi-orphan-scan`
  hebdomadaire qui rapporte sans corriger.
- **Validation** :
  ```sh
  find / -xdev \( -nouser -o -nogroup \) -ls 2>/dev/null
  ```
- **Contraintes / effets induits** : sur NixOS, le store contient parfois des
  UID transitoires ; whitelist `/nix/store` recommandée.

#### R54 — Sticky bit sur répertoires *world-writable*
- **Sévérité** : `minimal`.
- **Implémentation** : `systemd.tmpfiles.settings` pour `/tmp`, `/var/tmp`,
  `/dev/shm` (`1777 root:root`). Audit récursif.
- **Validation** :
  ```sh
  find / -xdev -type d -perm -0002 -a ! -perm -1000 -ls 2>/dev/null
  ```
- **Contraintes / effets induits** : nul.

#### R55 — Répertoires temporaires par utilisateur
- **Sévérité** : `intermediary`.
- **Implémentation** : `pam_namespace` ou `pam_mktemp` (cf. R67) ; activer via
  `security.pam.services.login.text` ajoutant
  `session required pam_namespace.so`. Alternative systemd-native :
  `PrivateTmp = true` au niveau service (voir R63) qui rend déjà `/tmp` privé
  par session.
- **Validation** : `grep -q pam_namespace /etc/pam.d/login`.
- **Contraintes / effets induits** : `pam_namespace` requiert
  `/etc/security/namespace.conf` ; conflit possible avec services qui
  attendent un `/tmp` partagé.

#### R56 — Éviter setuid/setgid arbitraires
- **Sévérité** : `minimal`.
- **Implémentation NixOS** : NixOS gère les setuid via `security.wrappers`.
  *Allowlist* `security.anssi.allowedSetuid` (file `*.txt` versionné) ;
  assertion sur `security.wrappers`.
- **Validation** :
  ```sh
  find / -xdev -type f -perm /6000 -ls 2>/dev/null | \
    grep -vFf /etc/anssi/setuid-allowed.txt
  ```
- **Contraintes / effets induits** : retirer `ping` (déjà capabilities `cap_net_raw+ep`
  sur NixOS, donc OK) ; retirer `mount.nfs`, `umount`, `traceroute` peut
  empêcher l'usage non-privilégié de l'outil ⇒ documenter.

#### R57 — Setuid root minimal
- **Sévérité** : `reinforced`.
- **Implémentation** : sous-ensemble de R56. Allowlist par défaut :
  `sudo`, `mount`, `umount`, `passwd`, `chsh`, `chfn`, `unix_chkpwd`,
  `newuidmap`, `newgidmap`, `su` (si non désactivé). Forcer
  `security.wrappers.<name>.setuid = false; capabilities = "…";` quand
  applicable (ex. `ping` → `cap_net_raw+ep`).
- **Validation** :
  ```sh
  find / -xdev -type f -perm -4000 -uid 0 -ls 2>/dev/null
  ```
- **Contraintes / effets induits** : casse les outils utilisateur usuels
  (`mount.cifs`, `crontab`) si non explicitement listés.

### 3.9 Paquets

#### R58 — Installer le strict nécessaire
- **Sévérité** : `minimal`.
- **Implémentation** : `environment.defaultPackages = [];` ;
  `documentation.man.enable = lib.mkDefault true;` (utile en SSH) ; assertion
  *soft* warning si `environment.systemPackages` dépasse un seuil
  (`security.anssi.maxSystemPackages` par défaut 60).
- **Validation** : Rust comparant
  `nix-store -q --requisites /run/current-system | wc -l` à un seuil
  configurable.
- **Contraintes / effets induits** : peut surprendre les utilisateurs
  habitués à `wget`/`curl`/`vim` par défaut ; documenter dans `motd`.

#### R59 — Dépôts de confiance
- **Sévérité** : `minimal`.
- **Implémentation** :
  - `nix.settings.substituters` ⊂ `security.anssi.trustedSubstituters` ;
  - `nix.settings.require-sigs = true;` ;
  - `nix.settings.trusted-public-keys` figé ;
  - `nix.settings.allowed-uris` restreint aux miroirs internes ;
  - `nix.settings.allow-import-from-derivation = false`.
- **Validation** :
  ```sh
  nix show-config | grep -E '^substituters|^trusted-public-keys|^require-sigs'
  ```
- **Contraintes / effets induits** : `allow-import-from-derivation=false` casse
  certains flakes complexes (Haskell, Python lourds) → documenter.

#### R60 — Dépôts durcis
- **Sévérité** : `reinforced`.
- **Implémentation** : option `security.anssi.useHardenedKernel = true;` ⇒
  `boot.kernelPackages = pkgs.linuxPackages_hardened`. Préférer aussi
  `pkgs.openssh_hpn` durci, glibc avec patches stack-clash, GnuTLS / OpenSSL
  build *fips* selon contexte.
- **Validation** :
  ```sh
  uname -r | grep -q hardened
  ```
- **Contraintes / effets induits** : `linux_hardened` peut traîner d'une
  version mineure ; les modules tiers (NVIDIA) parfois incompatibles.

#### R61 — Mises à jour régulières
- **Sévérité** : `minimal`.
- **Implémentation** :
  - `system.autoUpgrade.enable = true;`
  - `system.autoUpgrade.dates = "Sun 03:00";`
  - `system.autoUpgrade.allowReboot = false;` (notif manuelle pour reboot) ;
  - timer `nixos-version --revision` comparant le commit déployé au commit du
    canal `security.anssi.expectedChannel` (alerte si dérive > 7 jours).
- **Validation** : `systemctl is-enabled nixos-upgrade.timer`,
  comparaison `current-system` vs `latest`.
- **Contraintes / effets induits** : sur les serveurs critiques, `allowReboot`
  doit rester à `false` ; `kured` ou un orchestrateur doit ordonnancer les
  redémarrages.

### 3.10 Services

#### R62 — Désactiver les services non nécessaires
- **Sévérité** : `minimal`.
- **Implémentation** : module fournit `security.anssi.disabledServices` et
  inscrit `systemd.services.<svc>.enable = false;`. Liste par défaut en
  catégorie `server` : `cups`, `avahi-daemon`, `bluetooth`, `ModemManager`,
  `wpa_supplicant`, `accounts-daemon`, `geoclue`. Toujours désactivé :
  `telnetd`, `rsh`, `rlogin`, `tftpd`, `talkd`. En `client`, conserver
  `cups`/`bluetooth` selon le sous-tag.
- **Validation** : `systemctl list-unit-files --state=enabled` croisé avec
  *deny-list*.
- **Contraintes / effets induits** : couper `avahi` casse la découverte
  d'imprimantes ; couper `bluetooth` casse les claviers/souris BT.

#### R63 — Réduire les fonctionnalités des services
- **Sévérité** : `intermediary`.
- **Implémentation** : helper `mkHardenedService = svc: { … }` qui pose :
  ```nix
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  PrivateDevices = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectKernelLogs = true;
  ProtectClock = true;
  ProtectControlGroups = true;
  ProtectHostname = true;
  ProtectProc = "invisible";
  ProcSubset = "pid";
  NoNewPrivileges = true;
  RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
  RestrictNamespaces = true;
  RestrictRealtime = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  MemoryDenyWriteExecute = true;
  SystemCallArchitectures = "native";
  SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
  CapabilityBoundingSet = "";
  AmbientCapabilities = "";
  UMask = "0027";
  ```
  Surcharges par service (typ. nginx : ouvrir `/var/log/nginx`,
  `RestrictAddressFamilies` += `AF_NETLINK`).
- **Validation** : `systemd-analyze security <svc>` doit retourner *exposure
  level* ≤ 5.0.
- **Contraintes / effets induits** : `MemoryDenyWriteExecute=yes` casse JIT
  (Java, V8, .NET, LuaJIT) ⇒ tag `needs-jit` lève la contrainte par service ;
  `ProtectSystem=strict` impose de déclarer chaque répertoire d'écriture en
  `ReadWritePaths`.

#### R64 — Privilèges des services
- **Sévérité** : `reinforced`.
- **Implémentation** : assertion : tout service avec `User = "root"` doit
  déclarer `CapabilityBoundingSet` non vide *ou* être listé dans
  `security.anssi.rootServicesAllowed`.
- **Validation** :
  ```sh
  systemctl show '*.service' -p User -p CapabilityBoundingSet | \
    awk -v RS= '/User=root/ && !/CapabilityBoundingSet=[^[:space:]]+/'
  ```
- **Contraintes / effets induits** : audit lourd au démarrage du projet (chaque
  service hérité) ; permet une réduction progressive des privilèges.

#### R65 — Cloisonner les services
- **Sévérité** : `reinforced`.
- **Implémentation** : surcouches du helper R63 :
  `PrivateNetwork=yes` quand admissible, `PrivateUsers=yes` (sauf `User=root`),
  `IPAddressDeny=any` + `IPAddressAllow=…` pour les services à liste
  d'IP fixe ; `DeviceAllow` restreint. Conteneurisation systemd-nspawn /
  `containers.<n>` quand l'isolation namespace ne suffit plus.
- **Validation** : `systemd-analyze security` (score ≤ 4).
- **Contraintes / effets induits** : `PrivateNetwork=yes` rend l'IPC réseau
  impossible (donc inadapté aux daemons réseau) ; `PrivateUsers=yes` empêche
  la lecture de fichiers root sur l'hôte.

#### R66 — Durcir les composants de cloisonnement
- **Sévérité** : `high`.
- **Implémentation** :
  - Docker : `virtualisation.docker.daemon.settings = { userns-remap = "default";
    no-new-privileges = true; live-restore = true; icc = false; userland-proxy = false; };`
  - Podman : `virtualisation.podman.dockerCompat = false;` + `rootless = true`.
  - LXC/LXD : profils non-privilégiés par défaut.
  - K8s : `kubelet` avec `--protect-kernel-defaults`, `--read-only-port=0`.
  - gVisor (`runsc`) recommandé pour les workloads à risque.
- **Validation** :
  ```sh
  docker info --format '{{json .}}' | jq '.SecurityOptions, .UserNS'
  ```
- **Contraintes / effets induits** : `userns-remap` casse les bind-mounts
  d'hôte vers conteneur (UID décalé), nécessite migration des volumes ;
  `userland-proxy=false` requiert IP forwarding cohérent.

### 3.11 PAM

#### R67 — Authentifications PAM distantes sécurisées
- **Sévérité** : `intermediary`.
- **Implémentation** :
  - préférer `pam_sss` (SSSD avec TLS/LDAPS) ou `pam_krb5` (keytab host).
  - assertion : `pam_ldap` doit avoir `ssl=on`, `tls_reqcert=demand`,
    `tls_cacertfile=…`.
  - poser `pam_faillock` pour anti brute-force (cf. C10) :
    `auth required pam_faillock.so preauth deny=3 unlock_time=900`.
- **Validation** :
  ```sh
  grep -RE 'pam_ldap|pam_krb5|pam_sss' /etc/pam.d /etc/nslcd.conf 2>/dev/null
  ```
- **Contraintes / effets induits** : SSSD requiert un service supplémentaire
  (`services.sssd.enable = true;`) et un cache local (gestion d'expiration).

#### R68 — Stockage chiffré des mots de passe
- **Sévérité** : `minimal`.
- **Implémentation** :
  ```nix
  security.pam.services.passwd.rules.password.unix.args = [
    "obscure" "yescrypt" "rounds=11"
  ];
  ```
  Forcer également `/etc/login.defs` :
  `ENCRYPT_METHOD YESCRYPT`, `YESCRYPT_COST_FACTOR 11`.
- **Validation** :
  ```sh
  awk -F: '
  function bad(pw) {
      return (pw != "" && pw !~ /^[!*]/ && pw !~ /^\$/)
  }
  bad($2) {
      print "FAIL:", $1, "->", $2
  }
  ' /etc/shadow
  ```
- **Contraintes / effets induits** : si retour à un système ancien sans
  yescrypt, la base utilisateur est inutilisable en l'état (rotation requise).

Autres audits utiles :

```sh
# Affichage du type d'algorithme
awk -F: '
function classify(pw) {
    if (pw == "") return "no_password"
    if (pw ~ /^[!*]/) return "locked"
    if (pw ~ /^\$y\$/) return "yescrypt"
    if (pw ~ /^\$6\$/) return "sha512"
    if (pw ~ /^\$5\$/) return "sha256"
    if (pw ~ /^\$1\$/) return "md5"
    if (pw ~ /^\$2[aby]?\$/) return "bcrypt"
    if (pw ~ /^\$/) return "unknown_hash"
    return "PLAINTEXT_OR_INVALID"
}
{
    type = classify($2)

    # Affichage structuré
    printf "%-20s : %-22s", $1, type

    # Optionnel : afficher la valeur suspecte
    if (type == "PLAINTEXT_OR_INVALID") {
        printf " -> %s", $2
    }

    print ""
}
' /etc/shadow

# Comptes actifs
awk -F: '
$2 ~ /^\$/ {
    print "ACTIVE:", $1
}
' /etc/shadow
```

### 3.12 NSS

**Condition** : règles utiles uniquement avec un NSS actif.

#### R69 — Bases utilisateur distantes sécurisées
- **Sévérité** : `intermediary`.
- **Implémentation** : `services.sssd.enable = true;` (TLS via PKI interne) ;
  `services.openldap`/`services.nslcd` avec TLS (`ssl on`, `tls_cacertfile`,
  `tls_reqcert demand`). Interdire LDAP en clair (port 389 sans STARTTLS).
- **Validation** :
  ```sh
  grep -E '^ssl ' /etc/nslcd.conf
  ldapwhoami -ZZ -H ldap://… 2>&1 | grep -q 'Start TLS'
  ```
- **Contraintes / effets induits** : besoin d'une PKI fiable côté annuaire ;
  surcoût de maintenance des certs.

#### R70 — Comptes système ≠ comptes annuaire
- **Sévérité** : `intermediary`.
- **Implémentation** : assertion : DN bind utilisé par `nslcd`/`sssd` ne doit
  pas appartenir au groupe administrateur de l'annuaire (option déclarative
  `services.anssi.directoryBindDn` vs `directoryAdminDns`). Pour SSSD,
  utiliser un compte de service en lecture seule.
- **Validation** :
  ```sh
  grep -E '^binddn|^ldap_default_bind_dn' /etc/{nslcd.conf,sssd/sssd.conf}
  ```
- **Contraintes / effets induits** : nul si l'annuaire est correctement
  segmenté ; lourd s'il faut migrer.

### 3.13 Journalisation

#### R71 — Système de journalisation
- **Sévérité** : `reinforced`.
- **Implémentation** :
  ```nix
  services.journald.extraConfig = ''
    Storage=persistent
    Compress=yes
    Seal=yes
    ForwardToSyslog=yes
    MaxLevelStore=info
    MaxLevelSyslog=info
    RateLimitIntervalSec=30s
    RateLimitBurst=2000
    SystemMaxUse=2G
    SystemKeepFree=1G
  '';
  ```
  + *forwarder* : `services.rsyslogd` ou `services.syslog-ng` envoyant en
  TLS (RELP/TCP+TLS) vers le collecteur central. Préférer `omrelp`
  (ack applicatif) à TCP simple.
- **Validation** :
  ```sh
  journalctl --disk-usage
  journalctl --verify
  ss -lntp | grep -E ':(514|6514|601)\b'
  ```
- **Contraintes / effets induits** : `Seal=yes` requiert
  `journalctl --setup-keys` (clé d'audit hors-bande pour vérification) ;
  pertes de logs si le collecteur tombe → buffer local de taille adaptée.

#### R72 — Journaux dédiés par service
- **Sévérité** : `reinforced`.
- **Implémentation** : `services.rsyslogd.extraConfig` génère des règles
  `if $programname == 'foo' then -/var/log/foo.log` ; chaque fichier en
  `0640 syslog:adm` (`logrotate` quotidien). Garder les ACL d'origine du
  service (R50).
- **Validation** :
  ```sh
  for s in nginx sshd postgresql kanidm; do
    [ -f /var/log/$s.log ] && stat -c %a /var/log/$s.log
  done
  ```
- **Contraintes / effets induits** : multiplication des fichiers ; veiller à
  la rotation pour éviter la saturation de `/var/log` (cf. R28).

#### R73 — auditd
- **Sévérité** : `reinforced` · tag : `no-auditd`.
- **Implémentation** : `security.audit.enable = true;` +
  `security.audit.rules` reprenant le guide. Compléments :
  ```text
  -a exit,always -F arch=b64 -S clock_settime -S settimeofday -S adjtimex
  -a exit,always -F arch=b64 -S sethostname -S setdomainname
  -a exit,always -F arch=b64 -S kexec_load -S kexec_file_load
  -w /etc/sudoers      -p wa
  -w /etc/sudoers.d/   -p wa
  -w /var/log/auth.log -p wa
  -e 2                 # immuable
  ```
- **Validation** :
  ```sh
  auditctl -l | wc -l                    # > 0
  auditctl -s | grep -q 'enabled 2'      # immuable
  ```
- **Contraintes / effets induits** : I/O significatif (1–10 % CPU sur
  workload syscall-heavy) ; configuration immuable interdit la modif sans
  reboot — donc tester en staging.

### 3.14 Messagerie

**Condition** : service de messagerie actif.

#### R74 — Messagerie locale durcie
- **Sévérité** : `intermediary`.
- **Implémentation** : `services.opensmtpd` ou `services.postfix` avec
  `inet_interfaces = "loopback-only"`, `mydestination = "$myhostname,
  localhost"`, `smtpd_relay_restrictions = "reject_unauth_destination"`.
  Pour l'envoi sortant : `smtp_tls_security_level = "encrypt"`,
  `smtp_tls_loglevel = 1`.
- **Validation** :
  ```sh
  ss -lntp | awk '$4 ~ /:25$/ && $4 !~ /127.0.0.1|::1/ {print "fail:"$0}'
  ```
- **Contraintes / effets induits** : ne plus pouvoir recevoir de mails
  externes (par construction : *loopback only*).

#### R75 — Alias de messagerie
- **Sévérité** : `intermediary`.
- **Implémentation** : `services.postfix.aliases` ou
  `environment.etc."aliases".text` : tout compte service (`nobody`, `daemon`,
  `nginx`, `postgres`, `root`) ⇒ alias vers `security.anssi.adminMailbox`.
  Génération automatique à partir des `users.users` `isSystemUser`.
- **Validation** :
  ```sh
  postalias -q root /etc/aliases
  ```
- **Contraintes / effets induits** : nul si la passerelle SMTP sortante est
  fiable.

### 3.15 Intégrité du système de fichiers

#### R76 — Sceller / vérifier l'intégrité
- **Sévérité** : `high` · tag : `no-sealing`.
- **Implémentation** : `services.aide.enable = true;` (alternative
  `services.samhain`). Configuration AIDE : surveiller `/bin`, `/sbin`,
  `/usr`, `/etc`, `/boot` ; exclure `/var/log`, `/var/lib`, `/var/cache`,
  `/proc`, `/sys`, `/run`. Timer quotidien `systemd.timers.aide-check`.
  En NixOS, surveiller `/run/current-system/sw` plutôt que `/usr` (lien vers
  store immuable).
- **Validation** :
  ```sh
  aide --config=/etc/aide/aide.conf --check
  systemctl is-enabled aide-check.timer
  ```
- **Contraintes / effets induits** : scan complet long (15–60 min selon
  taille FS et CPU), I/O lourd ; planifier en heures creuses ;
  faux-positifs sur `/etc/resolv.conf` dynamique → exclusions explicites.

#### R77 — Protection de la base scellée
- **Sévérité** : `high`.
- **Implémentation** : DB AIDE signée GPG, copie distante via
  `services.anssi.aide.remoteCopy = { host = "…"; sshKey = …; };`. Clé privée
  stockée hors-ligne (smartcard/HSM). Hash de la DB signé inclus dans le
  rapport de conformité.
- **Validation** :
  ```sh
  gpg --verify /var/lib/aide/aide.db.gz.sig /var/lib/aide/aide.db.gz
  test -O /var/lib/aide/aide.db.gz                    # owner root
  stat -c %a /var/lib/aide/aide.db.gz | grep -q '^[46]00$'
  ```
- **Contraintes / effets induits** : nécessite une procédure de signature à
  chaque changement majeur (mise à jour du store NixOS) ; risque de
  désynchronisation entre la base scellée et l'état courant.

### 3.16 Services réseau

#### R78 — Cloisonner les services réseau
- **Sévérité** : `reinforced` · **Catégorie** : `server`.
- **Implémentation** : conteneurisation systemd-nspawn (`containers.<n>`)
  ou *VM légère* (microvm.nix) ; `PrivateNetwork=yes` quand l'inter-service
  n'est pas nécessaire. Politique nftables par défaut deny (cf. C4) avec
  zones explicites (`fw_zone = { internal, dmz, mgmt };`).
- **Validation** : `systemd-analyze security <svc>.service` ; chaque service
  exposé doit déclarer `IPAddressAllow`/`Deny` ou `RestrictAddressFamilies`
  cohérents.
- **Contraintes / effets induits** : effort de packaging non négligeable
  (modules NixOS containers à maintenir) ; latence inter-services ↑.

#### R79 — Durcir et surveiller les services exposés
- **Sévérité** : `intermediary`.
- **Implémentation** : `security.anssi.exposedServices` déclare les services
  publics. Le module pose :
  - `services.fail2ban.enable = true;` + `jails.<svc>` automatiques.
  - règles auditd ciblées (R73) ;
  - `services.prometheus.exporters.node.enable = true;` ;
  - HTTP : `services.nginx.commonHttpConfig` posant
    `add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";`,
    `add_header X-Content-Type-Options "nosniff";`,
    `add_header X-Frame-Options "DENY";`,
    `add_header Content-Security-Policy "default-src 'self'";`,
    `add_header Referrer-Policy "no-referrer";`,
    `ssl_protocols TLSv1.3 TLSv1.2;`,
    `ssl_ciphers <ANSSI ciphers>;`,
    `ssl_prefer_server_ciphers on;`.
- **Validation** :
  ```sh
  fail2ban-client status
  curl -sI https://… | grep -i strict-transport-security
  testssl.sh <host> | grep -E 'overall grade|TLSv1\.0|RC4'
  ```
- **Contraintes / effets induits** : CSP stricte casse certains outils sans
  *nonces* ; HSTS preload est irréversible — à ne poser qu'en domaine
  pleinement maîtrisé.

#### R80 — Surface réseau réduite
- **Sévérité** : `minimal`.
- **Implémentation** : assertion : tout service écoutant sur `0.0.0.0` ou `::`
  doit être déclaré dans `security.anssi.publicListeners`. Sinon imposer
  `ListenAddress 127.0.0.1`/`localhost`. Couplage systématique avec C4
  (firewall deny).
- **Validation** :
  ```sh
  ss -lntp | awk 'NR>1 && $4 ~ /^(0\.0\.0\.0|\*|\[::\]):/'
  ```
- **Contraintes / effets induits** : nécessite de connaître exactement la
  topologie d'écoute ; certains services (KDE Connect, mDNS) écoutent par
  défaut sur toutes les interfaces.

### 3.17 Mesures complémentaires (Annexe A & transverses)

> Ces règles n'ont pas de numéro ANSSI mais sont indispensables au respect
> de l'esprit du guide. Elles utilisent l'identifiant `Cn`.

#### C1 — Patches linux-hardened (Annexe A)
- **Sévérité** : `high` · tag : `kernel-recompile`.
- **Implémentation** :
  - `boot.kernelPackages = pkgs.linuxPackages_hardened;`
  - `boot.kernelParams += [ "extra_latent_entropy" ];`
  - sysctls `kernel.tiocsti_restrict = 1;`, `kernel.device_sidechannel_restrict = 1;`,
    `kernel.deny_new_usb = 0;` (ou `1` en `client` strict),
    `kernel.perf_event_paranoid = 3;` (sémantique étendue).
- **Validation** : `uname -r | grep -q hardened` ; `sysctl kernel.tiocsti_restrict`.
- **Contraintes / effets induits** : version mineure de retard sur upstream ;
  modules tiers non garantis compatibles ; `deny_new_usb=1` casse le
  hot-plug.

#### C2 — Lockdown LSM (Annexe A)
- **Sévérité** : `high`.
- **Implémentation** :
  - `boot.kernelParams += [ "lsm=lockdown,yama,bpf,landlock,…" "lockdown=confidentiality" ];`
  - `structuredExtraConfig.SECURITY_LOCKDOWN_LSM = yes;
    SECURITY_LOCKDOWN_LSM_EARLY = yes;
    LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY = yes;`.
- **Validation** :
  ```sh
  cat /sys/kernel/security/lockdown   # [confidentiality] ou [integrity]
  ```
- **Contraintes / effets induits** : interdit `kexec`, écriture `/dev/mem`,
  MSR, `/dev/kmem`, hibernation, ACPI custom methods, lecture certaines
  zones noyau ⇒ casse `dmidecode` selon zones, `flashrom`, `i2c-tools`.

#### C3 — USBGuard
- **Sévérité** : `reinforced` · **Catégorie** : `client` (par défaut),
  `server` recommandé · tag : `needs-usb-hotplug` pour exclusion.
- **Implémentation** : `services.usbguard.enable = true;` avec ruleset
  *allow id ::: vendor:product :::* généré à partir des périphériques
  validés à l'install, plus `ImplicitPolicyTarget = "block";`.
- **Validation** :
  ```sh
  usbguard list-devices | awk '{print $2}' | sort -u
  systemctl is-active usbguard
  ```
- **Contraintes / effets induits** : tout nouveau périphérique USB doit être
  *whitelisté* explicitement ; pour clavier/souris, pré-charger dans la
  policy ou risque de *lock-out*.

#### C4 — nftables avec politique deny-by-default
- **Sévérité** : `minimal` (firewall) → `reinforced` (politique stricte).
- **Implémentation** :
  - `networking.nftables.enable = true;`
  - `networking.firewall.enable = true;`
  - `networking.firewall.allowedTCPPorts = [];` par défaut (ouvrir
    explicitement).
  - chaîne *output* en *deny* sauf liste blanche (option avancée
    `security.anssi.firewall.egressAllowlist`).
- **Validation** :
  ```sh
  nft list ruleset | grep -E 'policy drop'
  ```
- **Contraintes / effets induits** : *egress filtering* casse les outils qui
  joignent des CDN externes (curl, dl noyau) ; à n'activer qu'avec un proxy
  HTTP(S) sortant maîtrisé.

#### C5 — Durcissement OpenSSH
- **Sévérité** : `intermediary`.
- **Implémentation** :
  ```nix
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitEmptyPasswords = "no";
      X11Forwarding = false;
      AllowAgentForwarding = "no";
      AllowTcpForwarding = "no";
      GatewayPorts = "no";
      LogLevel = "VERBOSE";
      MaxAuthTries = 3;
      LoginGraceTime = 30;
      ClientAliveInterval = 300;
      ClientAliveCountMax = 2;
      KexAlgorithms = [ "sntrup761x25519-sha512@openssh.com"
                        "curve25519-sha256" "curve25519-sha256@libssh.org" ];
      Ciphers     = [ "chacha20-poly1305@openssh.com"
                      "aes256-gcm@openssh.com" "aes128-gcm@openssh.com" ];
      Macs        = [ "hmac-sha2-512-etm@openssh.com"
                      "hmac-sha2-256-etm@openssh.com" ];
      HostKeyAlgorithms = [ "ssh-ed25519" "rsa-sha2-512" ];
    };
    banner = "/etc/issue.net";
  };
  ```
  Aligné sur la note ANSSI-NT-007 (OpenSSH).
- **Validation** :
  ```sh
  sshd -T | grep -E '^permitrootlogin|passwordauthentication|kex'
  ssh-audit localhost
  ```
- **Contraintes / effets induits** : *tunnels* SSH, agent forwarding et X11
  désactivés ⇒ workflows admin à adapter (préférer `ProxyJump`/`ssh -J`).

#### C6 — Chiffrement disque (LUKS2)
- **Sévérité** : `intermediary` (laptop), `reinforced` (serveur).
- **Implémentation** :
  - `boot.initrd.luks.devices.<name> = { device = "/dev/…"; allowDiscards = true;
    bypassWorkqueues = true; };`
  - clés liées au TPM2 si disponible (`crypttab` policy `tpm2-device=auto,
    tpm2-pcrs=0+2+7`) ;
  - swap chiffré : `swapDevices = [ { device = "/dev/…"; randomEncryption.enable = true; } ];`.
- **Validation** :
  ```sh
  cryptsetup status <name>
  blkid -t TYPE=crypto_LUKS
  ```
- **Contraintes / effets induits** : performances disque ↓ 5–15 % selon CPU
  AES-NI ; impossible d'extraire le disque pour récupération sans clé.

#### C7 — Synchronisation horaire authentifiée
- **Sévérité** : `intermediary`.
- **Implémentation** :
  - `services.chrony.enable = true;` ou `services.timesyncd.enable = true;`
    avec NTS : `servers = [ "time.cloudflare.com" ]; serverConf = "nts";`.
  - alternative : sources internes signées (chrony `key`).
- **Validation** :
  ```sh
  chronyc tracking | grep 'Leap status'
  chronyc authdata | awk '$2!="NTS" {print "fail:"$0}'
  ```
- **Contraintes / effets induits** : NTS requiert des serveurs compatibles ;
  trafic UDP/123 + TCP/4460 ouverts ; horloge faussée sur isolat réseau.

#### C8 — Résolveur DNS sécurisé
- **Sévérité** : `intermediary`.
- **Implémentation** :
  - `services.resolved.dnssec = "true";`
  - `services.resolved.dnsovertls = "true";`
  - `services.resolved.fallbackDns = []` (pas de fallback en clair).
- **Validation** :
  ```sh
  resolvectl status | grep -E 'DNSSEC|DNSOverTLS'
  ```
- **Contraintes / effets induits** : zones internes non-DNSSEC nécessitent
  `Domains=~example.internal` ciblé ; certains résolveurs publics ne font pas
  DNSSEC.

#### C9 — Désactivation des core dumps
- **Sévérité** : `reinforced`.
- **Implémentation** :
  - `systemd.coredump.enable = false;`
  - `security.pam.loginLimits = [ { domain = "*"; type = "hard"; item = "core";
    value = "0"; } ];`
  - sysctl `kernel.core_pattern = "|/bin/false"`.
- **Validation** :
  ```sh
  sysctl kernel.core_pattern
  ulimit -c
  ```
- **Contraintes / effets induits** : analyse post-mortem impossible ; en
  développement, prévoir un canal différent (env. dédié).

#### C10 — Anti brute-force et limites session
- **Sévérité** : `intermediary`.
- **Implémentation** :
  - `pam_faillock` (R31/R67) avec `deny=3 unlock_time=900 even_deny_root=no`.
  - `security.pam.loginLimits` : `nproc=2048`, `nofile=4096`, `core=0`,
    `maxlogins=10`.
  - `programs.fail2ban.enable = true;` côté sshd (cf. R79).
- **Validation** :
  ```sh
  faillock --user <u>
  cat /etc/security/limits.conf
  ```
- **Contraintes / effets induits** : un attaquant peut déclencher des
  blocages volontaires (DoS sur compte) → utiliser `even_deny_root=no` et
  prévoir compte de secours non bloquable physique.

#### C11 — Bannières et messages
- **Sévérité** : `minimal`.
- **Implémentation** :
  - `environment.etc."issue".text` et `environment.etc."issue.net".text`
    rappelant les conditions d'utilisation et la traçabilité.
  - `services.openssh.banner = "/etc/issue.net";` (cf. C5).
  - `motd` informatif (versions, contact RSSI).
- **Validation** :
  ```sh
  test -s /etc/issue.net
  ssh -o StrictHostKeyChecking=no localhost true 2>&1 | head
  ```
- **Contraintes / effets induits** : nul.

#### C12 — Restriction cron/at
- **Sévérité** : `minimal`.
- **Implémentation** :
  - `services.cron.allow = [ "root" "ops" ];`
  - `environment.etc."cron.deny".text = "ALL\n";` (priorité à `allow`).
  - `services.atd.allowList = [ "root" ];` (`/etc/at.allow`).
- **Validation** :
  ```sh
  cat /etc/cron.allow /etc/at.allow
  ```
- **Contraintes / effets induits** : utilisateurs non listés ne peuvent plus
  planifier de tâches ; à compenser par systemd-timer si besoin.

---

## 4. Recommandations sans implémentation directe

| Règle | Justification |
| ----- | -------------- |
| R1, R2 | Configuration matérielle / firmware hors NixOS. |
| R4 | Implémentable seulement avec une PKI préexistante ; expose un *hook*. |
| R46–R49 | SELinux non supporté sur NixOS (exception `base.nix`). |
| R37 | Méta-règle ; vérifie l'état d'au moins une R45/R46. |

Pour ces règles, le `checkScript` retourne `TODO` (code 2) afin que la
non-conformité reste visible sans faire échouer l'ensemble du rapport.

## 5. Synthèse des effets de bord majeurs (par criticité)

| Effet | Règle(s) déclenchante(s) | Atténuation |
| ----- | ------------------------ | ----------- |
| Perte SMT (≈ -30 % CPU multi-thread) | R8 (`mds=full,nosmt`, `l1tf=full,force`) | Acceptable hors HPC |
| Modules tiers à signer | R3, R4, R6, R18 | Pipeline build interne |
| `noexec /tmp` casse compilateurs | R28 | `TMPDIR=/run/user/$UID` |
| `MemoryDenyWriteExecute` casse JIT | R63, R65 | tag `needs-jit` par service |
| `kexec`/`hibernation`/`binfmt` désactivés | R23, C2 | tags dédiés |
| Hot-plug USB bloqué | C3, `kernel.deny_new_usb` | Pré-whitelist hardware |
| Egress filtering casse curl | C4 | Proxy sortant maîtrisé |
| TLS / SSH stricts cassent vieux clients | C5, R79 | Veille compatibilité |
| Auditd I/O lourd | R73 | Tuning rules + buffer |
| AIDE long scan | R76 | Heures creuses, exclusions |
| `unprivileged_userns=0` casse rootless | R9 | Renoncer à podman rootless ou exception |

## 6. Roadmap d'implémentation

Si on part sur une implémentation similaire à Sécurix :

1. Compléter `ruleset.nix` en activant les fichiers correspondant à chaque
   section (§ 2.5).
2. Ajouter le champ `sideEffects` au format de règle (§ 2) et l'inclure
   dans `complianceReport`.
3. Écrire le validateur Rust `anssi-validator` (§ 2.6) ; remplacer en
   priorité les `checkScript` shell complexes (R15–R27, R28, R56, R57,
   R63–R65, R76, R80, C2).
4. Ajouter un test VM (`nixosTests.anssi-compliance`) qui démarre une VM
   NixOS avec `security.anssi.level = "intermediary"` et exécute
   `anssi-nixos-compliance-check` ; le test échoue si une règle activée
   retourne un code non nul.
5. Documenter dans `anssi/README.md` les exceptions actives, leurs
   justifications, et les tags d'exclusion choisis pour chaque profil
   (`base`, `client`, `server`).
