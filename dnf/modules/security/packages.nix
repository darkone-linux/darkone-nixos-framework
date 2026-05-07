# Gestion des paquets et mises à jour (R58–R61). (wip)
#
# Couvre l'installation du strict nécessaire (R58), les dépôts de confiance (R59),
# les dépôts durcis (R60 : linux_hardened) et les mises à jour régulières (R61).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R59 — allow-import-from-derivation=false]
# Casse certains flakes complexes (Haskell, Python lourds avec générateurs Nix).
# Documenter les exceptions dans nix.settings.
# :::
#
# :::caution[R60 — linux_hardened]
# Le noyau linux_hardened peut avoir du retard d'une version mineure sur nixpkgs-unstable.
# Les modules tiers (NVIDIA, ZFS) ne sont pas garantis compatibles.
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
  cfg = config.darkone.security.packages;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.packages.enable = lib.mkEnableOption "Active la gestion des paquets ANSSI (R58–R61).";

    darkone.security.packages.trustedSubstituters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "https://cache.nixos.org" ];
      description = "Allowlist des binary caches Nix autorisés (R59).";
    };

    darkone.security.packages.trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
      description = "Clés publiques des binary caches autorisés (R59).";
    };
  };

  config = lib.mkMerge [
    { darkone.security.packages.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R58 — Installer le strict nécessaire (minimal, base)
        # sideEffects: surprend les utilisateurs habitués à wget/curl/vim par défaut
        (lib.mkIf (isActive "R58" "minimal" "base" [ ]) {

          # Vider les paquets par défaut de NixOS
          environment.defaultPackages = lib.mkDefault [ ];

          # La documentation man reste utile en SSH
          documentation.man.enable = lib.mkDefault true;

          # TODO: assertion soft warning si systemPackages dépasse un seuil
          # (option darkone.security.packages.maxSystemPackages à ajouter si souhaité)
        })

        # R59 — Dépôts de confiance (minimal, base)
        # sideEffects: allow-import-from-derivation=false casse certains flakes complexes
        (lib.mkIf (isActive "R59" "minimal" "base" [ ]) {
          nix.settings = {

            # Seuls les substituters listés dans trustedSubstituters sont autorisés
            substituters = cfg.trustedSubstituters;
            trusted-public-keys = cfg.trustedPublicKeys;
            require-sigs = true;

            # Restreindre les imports depuis les dérivations
            allow-import-from-derivation = false;

            # TODO: option pour restreindre allowed-uris aux miroirs internes
            # allowed-uris = [ "https://cache.nixos.org" ];
          };
        })

        # R60 — Dépôts durcis : noyau linux_hardened (reinforced, base)
        # Géré par kernel-build.nix via mainSecurityCfg.useHardenedKernel
        # sideEffects: retard version mineure, modules tiers potentiellement incompatibles
        (lib.mkIf (isActive "R60" "reinforced" "base" [ ] && mainSecurityCfg.useHardenedKernel) {
          boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_hardened;
        })

        # R61 — Mises à jour régulières (minimal, base)
        # DNF: gestion centralisée de l'upgrade, non applicable pour le moment...
        # sideEffects: sur serveurs critiques, allowReboot doit rester false
        # (lib.mkIf (isActive "R61" "minimal" "base" [ ]) {
        #   system.autoUpgrade = {
        #     enable = lib.mkDefault true;
        #     dates = lib.mkDefault "Sun 03:00";
        #     allowReboot = lib.mkDefault false; # Reboot manuel pour les serveurs

        #     # TODO: timer comparant current-system au dernier commit du canal
        #     # et alertant si dérive > 7 jours
        #   };
        # })
      ]
    ))
  ];
}
