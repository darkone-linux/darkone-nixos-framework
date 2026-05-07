# Comptes utilisateur et authentification (R30–R36). (wip)
#
# Couvre les comptes inutilisés (R30), la politique de mots de passe (R31),
# le verrouillage sur inactivité (R32), l'imputabilité admin (R33),
# les comptes de service (R34), l'unicité des comptes de service (R35)
# et l'umask (R36).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R30 — mutableUsers=false]
# NixOS n'autorise plus `passwd`/`useradd` ad hoc. Toute évolution de compte
# passe par un déploiement NixOS complet (`colmena apply`).
# :::
#
# :::caution[R36 — umask 0077]
# Casse la collaboration par groupes (`/srv/share`). Documenter que
# `chmod g+rwx <fichier>` est nécessaire pour le partage de groupe.
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
  cfg = config.darkone.security.users;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });
in
{
  options = {
    darkone.security.users.enable = lib.mkEnableOption "Active la gestion des comptes ANSSI (R30–R36).";
  };

  config = lib.mkMerge [
    { darkone.security.users.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R30 — Désactiver les comptes utilisateur inutilisés (minimal, base)
        # sideEffects: mutableUsers=false interdit passwd/useradd ad hoc
        (lib.mkIf (isActive "R30" "minimal" "base" [ ]) {
          users.mutableUsers = lib.mkForce false;

          # Désactiver les comptes non listés dans allowedActiveUsers
          # Note: DNF gère déjà users.mutableUsers=false dans core.nix
          # TODO: assertion sur allowedActiveUsers vs users.users réels
        })

        # R31 — Mots de passe robustes (minimal, base) — implémentation via PAM (R67/R68)
        # sideEffects: enforce_for_root interdit réinitialisation simple en rescue
        (lib.mkIf (isActive "R31" "minimal" "base" [ ]) {
          security.pam.services.passwd = {
            rules.password.pwquality = {
              control = "required";
              modulePath = "${pkgs.libpwquality}/lib/security/pam_pwquality.so";
              settings = {
                minlen = 12;
                minclass = 3;
                maxrepeat = 1;
                enforce_for_root = true;
              };
            };
          };

          # pam_faillock : verrouillage après 3 tentatives (cf. C10)
          security.pam.services.login.failDelay.enable = true;
        })

        # R32 — Verrouillage sur inactivité (intermediary, base)
        # sideEffects: TMOUT peut tuer les sessions tmux/screen foreground
        (lib.mkIf (isActive "R32" "intermediary" "base" [ ]) {

          # Verrouillage TTY : TMOUT en readonly (10 minutes)
          programs.bash.loginShellInit = ''
            readonly TMOUT=600
            export TMOUT
          '';

          # Console graphique : géré par les modules home-manager (swayidle, GNOME)
          # TODO: intégration avec darkone.graphic.* pour le verrouillage automatique
        })

        # R33 — Imputabilité des actions d'administration (intermediary, base)
        # sideEffects: sudo-io logs ~quelques Mo/jour sur serveurs interactifs
        (lib.mkIf (isActive "R33" "intermediary" "base" [ ]) {

          # Root désactivé (mot de passe verrouillé)
          users.users.root.hashedPassword = lib.mkDefault "!";

          # SSH : pas de connexion root directe
          services.openssh.settings.PermitRootLogin = lib.mkDefault "no";

          # sudo avec journalisation I/O (cf. sudo.nix pour la config complète)
          security.sudo.extraConfig = lib.mkDefault ''
            Defaults log_input, log_output, iolog_dir=/var/log/sudo-io
          '';

          # Répertoire pour les journaux sudo
          systemd.tmpfiles.rules = [ "d /var/log/sudo-io 0750 root adm -" ];
        })

        # R34 — Désactiver les comptes de service (intermediary, base)
        # sideEffects: aucun majeur, NixOS conforme par défaut
        (lib.mkIf (isActive "R34" "intermediary" "base" [ ]) {

          # NixOS pose isSystemUser=true par défaut pour les services
          # Assertion : vérifier que les comptes système ont shell nologin
          assertions = [
            {
              assertion = lib.all (
                user:
                !(!user.isNormalUser && user.uid or 1000 < 1000)
                || user.shell == pkgs.shadow or null
                || user.shell == "/run/current-system/sw/bin/nologin"
                || user.shell == null
              ) (lib.attrValues config.users.users);
              message = "R34: Les comptes de service doivent avoir un shell nologin.";
            }
          ];
          # TODO: renforcer l'assertion pour couvrir tous les cas (shadow, false, nologin)
        })

        # R35 — Comptes de service uniques (intermediary, base)
        # sideEffects: migration manuelle si un service hérité réutilise nobody
        (lib.mkIf (isActive "R35" "intermediary" "base" [ ]) {

          # Assertion : interdire User=nobody dans les services systemd
          assertions = [
            {
              assertion = lib.all (svc: (svc.serviceConfig or { }).User or "" != "nobody") (
                lib.attrValues config.systemd.services
              );
              message = "R35: Le compte 'nobody' ne doit pas être utilisé comme User= dans systemd.";
            }
          ];
        })

        # R36 — UMASK (reinforced, base)
        # sideEffects: 0077 casse la collaboration par groupes (/srv/share)
        (lib.mkIf (isActive "R36" "reinforced" "base" [ ]) {

          # Shell global
          environment.etc."profile.d/anssi-umask.sh".text = "umask 0077";

          # PAM : umask sur création de home
          security.pam.loginLimits = [
            {
              domain = "*";
              type = "-";
              item = "umask";
              value = "0077";
            }
          ];

          # Services systemd : UMask=0027 (moins strict mais raisonnable pour les services)
          # TODO: appliquer UMask=0027 aux services via un helper mkHardenedService (R63)
        })
      ]
    ))
  ];
}
