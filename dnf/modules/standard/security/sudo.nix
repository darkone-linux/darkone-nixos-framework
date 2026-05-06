# Durcissement sudo (R38–R44).
#
# Couvre le groupe dédié sudo (R38), les directives sudo durcies (R39),
# la restriction des cibles non-root (R40), la limitation NOEXEC (R41),
# l'interdiction des négations (R42), la spécification des arguments (R43)
# et l'usage de sudoedit (R44).
#
# :::caution[Activation]
# L'option `enable` suit `darkone.system.security.enable` par défaut.
# Les règles (Rxx/Cxx) s'activent selon le niveau, la catégorie et les
# excludes définis dans `darkone.system.security` (via `isActive`).
# :::
#
# :::caution[R39 — requiretty]
# `requiretty` fait échouer `ssh user@host sudo cmd` sans TTY alloué.
# L'option `-t` SSH est requise : `ssh -t user@host sudo cmd`.
# :::
#
# :::caution[R39 — rootpw]
# `rootpw` impose un mot de passe root partagé entre les admins.
# Préférer `targetpw` ou `runaspw` selon la politique d'équipe.
# :::

{
  lib,
  dnfLib,
  config,
  ...
}:
let
  mainSecurityCfg = config.darkone.system.security;
  cfg = config.darkone.security.sudo;
  isActive = dnfLib.mkIsActive (mainSecurityCfg // { inherit (cfg) enable; });

  adminMail = mainSecurityCfg.adminMailbox;
in
{
  options = {
    darkone.security.sudo.enable = lib.mkEnableOption "Active le durcissement sudo ANSSI (R38–R44).";

    darkone.security.sudo.allowedRootRules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Règles sudo autorisées à cibler root (R40). Les autres doivent viser un compte de service.";
    };
  };

  config = lib.mkMerge [
    { darkone.security.sudo.enable = lib.mkDefault mainSecurityCfg.enable; }

    (lib.mkIf cfg.enable (
      lib.mkMerge [

        # R38 — Groupe dédié sudo (reinforced, base)
        (lib.mkIf (isActive "R38" "reinforced" "base" [ ]) {

          # execWheelOnly : sudo réservé aux membres du groupe wheel
          security.sudo.execWheelOnly = true;

          # TODO: option pour créer un groupe sudoers distinct de wheel
          # users.groups.sudoers = { };
        })

        # R39 — Directives sudo durcies (intermediary, base)
        (lib.mkIf (isActive "R39" "intermediary" "base" [ ]) {
          security.sudo.extraConfig = ''
            Defaults  noexec, requiretty, use_pty, umask=0027
            Defaults  ignore_dot, env_reset
            Defaults  log_input, log_output, iolog_dir=/var/log/sudo-io
            Defaults  passwd_timeout=1, timestamp_timeout=5
            ${lib.optionalString (
              adminMail != ""
            ) "Defaults  mailto=\"${adminMail}\", mail_badpass, mail_no_user"}
          '';

          # Répertoire pour les journaux sudo I/O
          systemd.tmpfiles.rules = [ "d /var/log/sudo-io 0750 root adm -" ];
        })

        # R40 — Cibles non-root pour sudo (intermediary, base)
        # sideEffects: oblige la création de comptes de service intermédiaires
        (lib.mkIf (isActive "R40" "intermediary" "base" [ ]) {
          assertions = [
            {
              # Vérifier qu'aucune règle extraRules ne cible root sauf sudo.allowedRootRules
              assertion = lib.all (
                rule:
                rule.runAs or "" != "root"
                || lib.elem (lib.concatStringsSep "," (rule.commands or [ ])) cfg.allowedRootRules
              ) (config.security.sudo.extraRules or [ ]);
              message =
                "R40: Les règles sudo ciblant root doivent être listées dans "
                + "darkone.security.sudo.allowedRootRules.";
            }
          ];
        })

        # R41 — Limiter NOEXEC override (reinforced, base)
        # sideEffects: empêche sudo -E env avec variables dynamiques
        (lib.mkIf (isActive "R41" "reinforced" "base" [ ]) {
          assertions = [
            {
              # Vérifier l'absence de EXEC: sans liste de commandes
              # TODO: parser security.sudo.extraConfig pour détecter "EXEC:" nu
              assertion = true;
              message = "R41: EXEC: sans liste de commandes explicite est interdit dans sudoers.";
            }
          ];
        })

        # R42 — Bannir les négations (intermediary, base)
        (lib.mkIf (isActive "R42" "intermediary" "base" [ ]) {
          assertions = [
            {
              # TODO: vérifier l'absence de `!` dans security.sudo.extraRules et extraConfig
              assertion = true;
              message = "R42: Les négations (!) sont interdites dans les règles sudo.";
            }
          ];
        })

        # R43 — Préciser les arguments (intermediary, base)
        # sideEffects: nombreuses règles à écrire pour les commandes complexes
        # Validation : cvtsudoers -f json + Rust check (phase ultérieure)

        # R44 — sudoedit (intermediary, base)
        # sideEffects: sudoedit impose EDITOR cohérent dans l'environnement
        (lib.mkIf (isActive "R44" "intermediary" "base" [ ]) {
          assertions = [
            {
              # TODO: vérifier que vi/vim/nano/emacs ne sont pas ciblés directement dans sudoers
              assertion = true;
              message = "R44: Utiliser sudoedit au lieu d'appeler vi/vim/nano/emacs via sudo.";
            }
          ];
        })
      ]
    ))
  ];
}
