# Configuration matérielle et démarrage sécurisé (R1–R7). (wip)
#
# Couvre le Secure Boot UEFI (R3), lanzaboote, le mot de passe chargeur (R5),
# les UKI signées (R6) et l'IOMMU (R7). R1 et R2 (matériel/firmware) sont
# hors périmètre NixOS et produisent uniquement une note dans le rapport.
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R3/R4 — Secure Boot]
# L'intégration lanzaboote nécessite un premier enrôlement physique des clés
# (`sbctl enroll-keys`). R4 (remplacement des clés Microsoft) comporte un
# risque de brickage si la machine ne permet pas la restauration.
# :::
#
# :::caution[R7 — IOMMU]
# Peut causer des plantages avec certains GPU/Thunderbolt ; surcoût I/O ~5–15 %
# sur baies NVMe à très haut débit.
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

  # Détection de l'architecture CPU pour les paramètres IOMMU (R7)
  cpuVendor =
    if pkgs.stdenv.hostPlatform.isAarch64 then
      "arm"
    else if pkgs.stdenv.hostPlatform.isx86_64 then

      # Intel vs AMD : détecté au build, affiné au runtime dans le checkScript
      "x86"
    else
      "unknown";
in
{
  options = {
    darkone.security.preboot.enable = lib.mkEnableOption "Active le démarrage sécurisé ANSSI — Secure Boot, IOMMU (R1–R7).";
  };

  config = lib.mkMerge [
    { darkone.security.preboot.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R1 — Choisir et configurer son matériel (high, base)
        # Aucune implémentation NixOS possible. Checkscript manuel uniquement.
        # sideEffects: aucun

        # R2 — Configurer le BIOS/UEFI (intermediary, base)
        # Aucune implémentation NixOS possible ; exposition d'un futur hook dmidecode.
        # sideEffects: aucun

        # R3 — Activer le démarrage sécurisé UEFI (intermediary, base)
        # sideEffects: modules tiers (NVIDIA, ZFS OOT) doivent être signés
        (lib.mkIf (isActive "R3" "intermediary" "base" [ ]) {

          # Option A : lanzaboote (recommandé ANSSI)
          # boot.lanzaboote = {
          #   enable = true;
          #   pkiBundle = "/var/lib/sbctl";
          # };
          # boot.loader.systemd-boot.enable = lib.mkForce false;

          # Option B : systemd-boot simple (sans signature UKI)
          boot.loader.systemd-boot.enable = lib.mkDefault true;
          boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

          # DÉCISION ARCHITECTURALE : lanzaboote vs systemd-boot simple.
          # Lanzaboote est recommandé pour R3 complet mais nécessite un enrôlement
          # physique des clés. À configurer via darkone.system.security.secureBootImpl
          # (option à ajouter si nécessaire). Pour l'instant, systemd-boot par défaut.
        })

        # R4 — Remplacer les clés préchargées (high, base)
        # sideEffects: risque de brickage, nécessite une PKI préexistante
        # Implémentation : hook d'enrôlement sbctl — hors périmètre automatisé.
        # L'opérateur doit exécuter manuellement : sbctl create-keys && sbctl enroll-keys
        # Le checkScript vérifiera l'état des clés.

        # R5 — Mot de passe chargeur de démarrage (intermediary, base)
        # sideEffects: perte du mot de passe = rescue media obligatoire
        (lib.mkIf (isActive "R5" "intermediary" "base" [ ]) {

          # Implémentation via Secure Boot (R3+R4) : cmdline signée = menu non modifiable.
          # Pour GRUB : boot.loader.grub.users."admin".hashedPasswordFile = ...;
          # NixOS standard utilise systemd-boot sans mot de passe natif → R3 obligatoire.
          # TODO: ajouter option darkone.system.security.bootloaderImpl = "secureboot" | "grub"
        })

        # R6 — Protéger la cmdline noyau et l'initramfs (high, base)
        # sideEffects: modifier la cmdline impose une re-signature, modules tiers via pipeline Nix
        (lib.mkIf (isActive "R6" "high" "base" [ ]) {

          # UKI (Unified Kernel Image) signée avec lanzaboote — cf. R3
          # boot.initrd.systemd.enable = true;
          # boot.uki.enable = true;
          # TODO: conditionner à boot.lanzaboote.enable ou boot.uki.enable
        })

        # R7 — Activer l'IOMMU (reinforced, base)
        # sideEffects: plantages possibles GPU/Thunderbolt, surcoût I/O ~5-15% NVMe
        (lib.mkIf (isActive "R7" "reinforced" "base" [ ]) {
          boot.kernelParams =
            if cpuVendor == "arm" then
              [ "iommu.passthrough=0" ]
            else
              [
                # Intel et AMD : paramètre commun + paramètre spécifique au runtime
                # Le paramètre intel_iommu=on / amd_iommu=on est détecté par le kernel
                # sur les systèmes modernes ; on force iommu=force pour les deux.
                "iommu=force"
                "iommu.passthrough=0"
                "iommu.strict=1"
              ];

          # TODO: ajouter intel_iommu=on / amd_iommu=on selon hostPlatform.cpuType
          # quand l'info est disponible au build, sinon documenter le runtime check.
        })
      ]
    ))
  ];
}
