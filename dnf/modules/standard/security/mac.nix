# Contrôle d'accès obligatoire — MAC (R37, R45–R49).
#
# R37 est une règle méta : valide si au moins R45 (AppArmor) ou R46 (SELinux)
# est active. SELinux (R46–R49) n'est pas supporté sur NixOS et est exclu par
# défaut via `exceptions`. AppArmor (R45) est partiellement supporté.
#
# :::tip[Sandboxing]
# A défaut, NixOS exploite souvent les options de systemd (systemd sandboxing)
# pour isoler les services.
# :::
#
# :::note[NixOS et MAC]
# SELinux est structurellement non supporté sur NixOS (R46–R49 en exception par
# défaut). AppArmor est disponible mais avec peu de profils prêts à l'emploi.
# L'absence de profil pour un service exposé est un faux sentiment de sécurité.
# :::
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[Tag no-mac]
# Utiliser le tag `no-mac` dans `excludes` pour désactiver R37 et R45 avec une
# justification explicite dans `exceptions.R37.rationale`.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.mac;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.mac.enable = lib.mkEnableOption "Active le module MAC ANSSI — AppArmor/SELinux (R37, R45–R49).";
  };

  config = lib.mkMerge [
    { darkone.security.mac.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R37 — Utiliser un MAC (reinforced, base, tag: no-mac)
        # Règle méta : valide ssi R45 OU R46 est actif.
        # Sur NixOS : R46 est en exception → R37 valide seulement si R45 actif.
        (lib.mkIf (isActive "R37" "reinforced" "base" [ "no-mac" ]) {
          # Assertion : au moins un MAC actif
          assertions = [
            {
              assertion =
                config.security.apparmor.enable

                # SELinux non supporté : pas de vérification
                || lib.hasAttr "R37" mainSecurityCfg.exceptions;
              message =
                "R37: Au moins un MAC (AppArmor) doit être actif au niveau 'reinforced'. "
                + "Utiliser exceptions.R37.rationale pour documenter l'absence de MAC.";
            }
          ];
        })

        # R45 — AppArmor (reinforced, base, tag: no-mac)
        # sideEffects: peu de profils NixOS prêts à l'emploi ; profils maison à maintenir
        (lib.mkIf (isActive "R45" "reinforced" "base" [ "no-mac" ]) {
          security.apparmor = {
            enable = true;

            # Profils en mode enforce (pas learn/complain)
            # TODO: ajouter les profils DNF maison pour les services enregistrés
            packages = [ ]; # ex: pkgs.apparmor-profiles
            policies = {
              # Exemple de profil inline :
              # "dnf-nginx".profile = ''
              #   /usr/sbin/nginx {
              #     ...
              #   }
              # '';
            };
          };
        })

        # R46 — SELinux targeted enforcing (high, base) → exception NixOS par défaut
        # R47 — Confiner les utilisateurs interactifs (high) → idem
        # R48 — Variables booléennes SELinux (high) → idem
        # R49 — Désinstaller les outils debug SELinux (high) → idem
        # Ces règles sont dans mainSecurityCfg.exceptions par défaut (voir security.nix).
        # En l'absence de SELinux : le checkScript retournerait code 2 (indéterminé).

      ]
    ))
  ];
}
